using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace PcLimiter
{
    public sealed class AppRule
    {
        public string Path { get; set; }
        public bool UploadEnabled { get; set; }
        public int UploadMbps { get; set; }
        public bool DownloadEnabled { get; set; }
        public int DownloadMbps { get; set; }
    }

    public sealed class Settings
    {
        public bool Enabled { get; set; }
        public int UploadMbps { get; set; }
        public bool DownloadEnabled { get; set; }
        public int DownloadMbps { get; set; }
        public AppRule[] Apps { get; set; }
    }

    internal sealed class RateBudget
    {
        private readonly double bytesPerTick;
        private readonly double burstTicks;
        private double nextAvailable;

        internal RateBudget(int mbps)
        {
            double bytesPerSecond = mbps * 125000.0;
            bytesPerTick = bytesPerSecond / Stopwatch.Frequency;
            burstTicks = Math.Max(PacketDriver.MaxFrame, bytesPerSecond / 50) / bytesPerTick;
        }

        internal bool Reserve(int size, long now, long deadline, out long due)
        {
            double finish = Math.Max(nextAvailable, now - burstTicks) + size / bytesPerTick;
            due = Math.Max(now, (long)Math.Ceiling(finish));
            if (due > deadline) return false;
            nextAvailable = finish;
            return true;
        }
    }

    internal sealed class PacketLimiter : ServiceBase
    {
        internal const string ServiceId = "PCUploadLimitShaper";
        private static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;
        private static readonly string SettingsFile = Path.Combine(Root, "Settings.json");
        private static readonly string StatusFile = Path.Combine(Root, "PacketLimiter.status");
        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private Thread thread;

        private PacketLimiter() { ServiceName = ServiceId; CanShutdown = true; }

        private static int Main(string[] arguments)
        {
            if (arguments.Length == 1 && arguments[0] == "--probe")
            {
                try
                {
                    using (var driver = new PacketDriver())
                    {
                        foreach (var pair in driver.ConnectedAdapters()) Console.WriteLine(pair.Value);
                    }
                    return 0;
                }
                catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
            }
            ServiceBase.Run(new PacketLimiter());
            return 0;
        }

        protected override void OnStart(string[] arguments)
        {
            thread = new Thread(Work);
            thread.IsBackground = true;
            thread.Start();
        }

        protected override void OnShutdown() { OnStop(); }
        protected override void OnStop()
        {
            stop.Set();
            if (thread != null && !thread.Join(4500)) { RequestAdditionalTime(5000); thread.Join(4000); }
        }

        private void Work()
        {
            string lastStatus = null;
            var serializer = new JavaScriptSerializer();
            timeBeginPeriod(1);
            try
            {
                while (!stop.WaitOne(0))
                {
                    try
                    {
                        using (var driver = new PacketDriver())
                        {
                            string settingsText = ReadSettings();
                            var settings = serializer.Deserialize<Settings>(settingsText);
                            var rules = settings.Apps ?? new AppRule[0];
                            uint options = settings.DownloadEnabled && settings.DownloadMbps > 0 ? 2U : 0U;
                            foreach (var rule in rules)
                            {
                                if (rule.UploadEnabled && rule.UploadMbps > 0) options |= 1;
                                if (rule.DownloadEnabled && rule.DownloadMbps > 0) options |= 2;
                            }
                            if (options == 0)
                            {
                                WriteStatus("Ready", ref lastStatus);
                                stop.WaitOne(500);
                                continue;
                            }

                            var adapters = driver.ConnectedAdapters();
                            if (adapters.Count == 0)
                            {
                                WriteStatus("Waiting for a connected network adapter", ref lastStatus);
                                stop.WaitOne(1000);
                                continue;
                            }
                            using (var session = new PacketSession(driver, adapters, options, settings))
                            {
                                WriteStatus("Active", ref lastStatus);
                                session.Run(stop, delegate { return settingsText == ReadSettings(); });
                            }
                        }
                    }
                    catch (Exception error)
                    {
                        WriteStatus(error.Message, ref lastStatus);
                        stop.WaitOne(1000);
                    }
                }
            }
            finally { timeEndPeriod(1); }
        }

        private static string ReadSettings()
        {
            using (var source = new FileStream(SettingsFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(source)) return reader.ReadToEnd();
        }

        private static void WriteStatus(string text, ref string previous)
        {
            if (previous == text) return;
            try { File.WriteAllText(StatusFile, text); previous = text; }
            catch (IOException) { }
        }

        [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint interval);
        [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint interval);
    }

    internal sealed unsafe class PacketSession : IDisposable
    {
        private const int QueueLimit = 4096;
        private static readonly long MaxUploadWait = Stopwatch.Frequency / 6;
        private static readonly long MaxDownloadWait = Stopwatch.Frequency / 2;
        private readonly ManualResetEvent available = new ManualResetEvent(false);
        private readonly SortedSet<Frame> delayed = new SortedSet<Frame>();
        private readonly Stack<byte[]> buffers = new Stack<byte[]>();
        private readonly Dictionary<AppRule, RateBudget> upload = new Dictionary<AppRule, RateBudget>();
        private readonly Dictionary<AppRule, RateBudget> download = new Dictionary<AppRule, RateBudget>();
        private readonly ConnectionOwners owners = new ConnectionOwners();
        private readonly List<IntPtr> attached = new List<IntPtr>();
        private readonly IDictionary<IntPtr, string> adapters;
        private readonly PacketDriver driver;
        private readonly Settings settings;
        private readonly RateBudget globalUpload;
        private readonly RateBudget globalDownload;
        private long sequence;
        private long lastOwnerRefresh;

        private sealed class Frame : IComparable<Frame>
        {
            internal byte[] Buffer;
            internal IntPtr Adapter;
            internal bool Outbound;
            internal long Due;
            internal long Deadline;
            internal long Sequence;
            internal int Size;
            internal RateBudget Global;
            public int CompareTo(Frame other)
            {
                int time = Due.CompareTo(other.Due);
                return time == 0 ? Sequence.CompareTo(other.Sequence) : time;
            }
        }

        internal PacketSession(PacketDriver driver, IDictionary<IntPtr, string> adapters, uint mode, Settings settings)
        {
            this.driver = driver;
            this.adapters = adapters;
            this.settings = settings;
            foreach (var rule in settings.Apps ?? new AppRule[0])
            {
                if (rule.UploadEnabled && rule.UploadMbps > 0) upload[rule] = new RateBudget(rule.UploadMbps);
                if (rule.DownloadEnabled && rule.DownloadMbps > 0) download[rule] = new RateBudget(rule.DownloadMbps);
            }
            if (settings.Enabled && settings.UploadMbps > 0 && (mode & 1) != 0) globalUpload = new RateBudget(settings.UploadMbps);
            if (settings.DownloadEnabled && settings.DownloadMbps > 0) globalDownload = new RateBudget(settings.DownloadMbps);

            try
            {
                RefreshOwners();
                foreach (var adapter in adapters)
                {
                    driver.Attach(adapter.Key, available.SafeWaitHandle.DangerousGetHandle(), mode);
                    attached.Add(adapter.Key);
                }
            }
            catch { Dispose(); throw; }
        }

        internal void Run(WaitHandle stop, Func<bool> settingsUnchanged)
        {
            var waitHandles = new WaitHandle[] {stop, available};
            long nextSettings = 0;
            long nextOwners = 0;
            long nextAdapters = 0;
            var packet = new byte[PacketDriver.BufferSize];
            fixed (byte* storage = packet)
            {
                while (!stop.WaitOne(0))
                {
                    long now = Stopwatch.GetTimestamp();
                    if (now >= nextSettings)
                    {
                        if (!settingsUnchanged()) return;
                        nextSettings = now + Stopwatch.Frequency / 2;
                    }
                    if (now >= nextOwners)
                    {
                        RefreshOwners();
                        nextOwners = now + Stopwatch.Frequency / 2;
                    }
                    if (now >= nextAdapters)
                    {
                        var current = driver.ConnectedAdapters();
                        if (current.Count != adapters.Count) return;
                        foreach (var item in adapters) if (!current.ContainsKey(item.Key)) return;
                        nextAdapters = now + Stopwatch.Frequency * 3;
                    }

                    ReleaseDue();
                    available.Reset();
                    bool busy = false;
                    foreach (var adapter in attached)
                    {
                        for (int count = 0; count < 64; count++)
                        {
                            if (!driver.Read(adapter, storage)) break;
                            busy = true;
                            QueueOrForward(adapter, packet, storage);
                        }
                    }
                    if (busy) continue;
                    int wait = delayed.Count == 0 ? 50 : Math.Max(0, Math.Min(50,
                        (int)Math.Ceiling((delayed.Min.Due - Stopwatch.GetTimestamp()) * 1000.0 / Stopwatch.Frequency)));
                    WaitHandle.WaitAny(waitHandles, wait);
                }
            }
        }

        private void RefreshOwners()
        {
            if (upload.Count > 0 || download.Count > 0)
            {
                owners.Refresh(settings.Apps);
                lastOwnerRefresh = Stopwatch.GetTimestamp();
            }
        }

        private void QueueOrForward(IntPtr adapter, byte[] packet, byte* storage)
        {
            int size = *(int*)(storage + 20);
            if (size < 14 || size > PacketDriver.MaxFrame) return;
            bool outbound = (*(int*)(storage + 16) & 1) != 0;
            RateBudget global = outbound ? globalUpload : globalDownload;
            var appBudgets = outbound ? upload : download;
            RateBudget app = null;
            if (appBudgets.Count != 0)
            {
                AppRule owner;
                if (!owners.TryFind(storage + PacketDriver.FrameOffset, size, outbound, out owner) &&
                    Stopwatch.GetTimestamp() - lastOwnerRefresh > Stopwatch.Frequency / 12)
                {
                    RefreshOwners();
                    owners.TryFind(storage + PacketDriver.FrameOffset, size, outbound, out owner);
                }
                if (owner != null) appBudgets.TryGetValue(owner, out app);
            }

            byte* ethernet = storage + PacketDriver.FrameOffset;
            int etherType = ethernet[12] << 8 | ethernet[13];
            if ((global == null && app == null) || (etherType != 0x0800 && etherType != 0x86dd && etherType != 0x8100 && etherType != 0x88a8))
            {
                driver.Send(adapter, storage, outbound);
                return;
            }
            if (delayed.Count >= QueueLimit) return;

            long now = Stopwatch.GetTimestamp();
            long deadline = now + (outbound ? MaxUploadWait : MaxDownloadWait);
            long due;
            var first = app ?? global;
            if (!first.Reserve(size, now, deadline, out due)) return;
            var second = app == null ? null : global;
            if (due == now && second != null)
            {
                if (!second.Reserve(size, now, deadline, out due)) return;
                second = null;
            }
            if (due == now)
            {
                driver.Send(adapter, storage, outbound);
                return;
            }

            byte[] copy = buffers.Count == 0 ? new byte[PacketDriver.BufferSize] : buffers.Pop();
            Buffer.BlockCopy(packet, 0, copy, 0, PacketDriver.FrameOffset + size);
            var frame = new Frame { Adapter = adapter, Buffer = copy, Outbound = outbound, Global = second,
                Deadline = deadline, Due = due, Sequence = sequence++, Size = size };
            delayed.Add(frame);
        }

        private void ReleaseDue()
        {
            while (delayed.Count > 0)
            {
                var frame = delayed.Min;
                long now = Stopwatch.GetTimestamp();
                if (frame.Due > now) return;
                delayed.Remove(frame);
                if (frame.Global != null)
                {
                    long due;
                    if (!frame.Global.Reserve(frame.Size, now, frame.Deadline, out due)) { buffers.Push(frame.Buffer); continue; }
                    frame.Global = null;
                    if (due > now) { frame.Due = due; delayed.Add(frame); continue; }
                }
                fixed (byte* storage = frame.Buffer) driver.Send(frame.Adapter, storage, frame.Outbound);
                buffers.Push(frame.Buffer);
            }
        }

        public void Dispose()
        {
            foreach (var adapter in attached) driver.Detach(adapter);
            foreach (var frame in delayed)
                fixed (byte* storage = frame.Buffer) driver.Send(frame.Adapter, storage, frame.Outbound);
            delayed.Clear();
            attached.Clear();
            available.Dispose();
        }
    }

    internal sealed unsafe class PacketDriver : IDisposable
    {
        internal const int FrameOffset = 52;
        internal const int MaxFrame = 9014;
        internal const int BufferSize = FrameOffset + MaxFrame;
        private readonly IntPtr handle;

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct AdapterMode { public IntPtr Adapter; public uint Flags; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct Request { public IntPtr Adapter; public IntPtr Buffer; }

        internal PacketDriver()
        {
            if (IntPtr.Size != 8) throw new PlatformNotSupportedException("The packet backend requires x64 Windows.");
            handle = OpenFilterDriver("NDISRD");
            if (handle == IntPtr.Zero || handle == new IntPtr(-1)) throw new IOException("Windows Packet Filter could not be opened.");
            if (!IsDriverLoaded(handle)) { CloseFilterDriver(handle); throw new IOException("Windows Packet Filter is unavailable."); }
        }

        internal Dictionary<IntPtr, string> ConnectedAdapters()
        {
            const int adapterCount = 32;
            const int nameSize = 256;
            var connected = new Dictionary<Guid, string>();
            foreach (var device in NetworkInterface.GetAllNetworkInterfaces())
            {
                Guid id;
                if (device.OperationalStatus != OperationalStatus.Up || !Guid.TryParse(device.Id, out id)) continue;
                foreach (var gateway in device.GetIPProperties().GatewayAddresses)
                {
                    if (!gateway.Address.Equals(IPAddress.Any) && !gateway.Address.Equals(IPAddress.IPv6Any))
                        connected[id] = device.Name;
                }
            }

            var adapters = new Dictionary<IntPtr, string>();
            var list = new byte[4 + adapterCount * (nameSize + 8 + 4 + 6 + 2)];
            fixed (byte* data = list)
            {
                if (!GetTcpipBoundAdaptersInfo(handle, (IntPtr)data)) return adapters;
                int count = Math.Min(adapterCount, *(int*)data);
                for (int index = 0; index < count; index++)
                {
                    string device = Encoding.ASCII.GetString(list, 4 + index * nameSize, nameSize).Split('\0')[0];
                    int brace = device.LastIndexOf('{');
                    Guid id;
                    string name;
                    if (brace >= 0 && Guid.TryParse(device.Substring(brace), out id) && connected.TryGetValue(id, out name))
                    {
                        var adapter = new IntPtr(*(long*)(data + 4 + adapterCount * nameSize + index * 8));
                        adapters[adapter] = name;
                    }
                }
            }
            return adapters;
        }

        internal void Attach(IntPtr adapter, IntPtr signal, uint flags)
        {
            var mode = new AdapterMode { Adapter = adapter };
            if (!GetAdapterMode(handle, ref mode) || mode.Flags != 0) throw new IOException("An adapter is already filtered or unavailable.");
            if (!SetPacketEvent(handle, adapter, signal)) throw new IOException("Could not register the adapter packet event.");
            mode.Flags = flags;
            if (SetAdapterMode(handle, ref mode)) return;
            SetPacketEvent(handle, adapter, IntPtr.Zero);
            throw new IOException("Could not enable packet throttling on the adapter.");
        }

        internal void Detach(IntPtr adapter)
        {
            var mode = new AdapterMode { Adapter = adapter };
            SetAdapterMode(handle, ref mode);
            SetPacketEvent(handle, adapter, IntPtr.Zero);
        }

        internal bool Read(IntPtr adapter, byte* buffer)
        {
            var request = new Request { Adapter = adapter, Buffer = (IntPtr)buffer };
            return ReadPacket(handle, ref request);
        }

        internal void Send(IntPtr adapter, byte* buffer, bool outbound)
        {
            var request = new Request { Adapter = adapter, Buffer = (IntPtr)buffer };
            if (outbound) SendPacketToAdapter(handle, ref request);
            else SendPacketToMstcp(handle, ref request);
        }

        public void Dispose() { CloseFilterDriver(handle); }

        [DllImport("ndisapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] private static extern IntPtr OpenFilterDriver(string name);
        [DllImport("ndisapi.dll")] private static extern void CloseFilterDriver(IntPtr handle);
        [DllImport("ndisapi.dll")] [return: MarshalAs(UnmanagedType.I1)] private static extern bool IsDriverLoaded(IntPtr handle);
        [DllImport("ndisapi.dll")] private static extern bool GetTcpipBoundAdaptersInfo(IntPtr handle, IntPtr adapters);
        [DllImport("ndisapi.dll")] private static extern bool GetAdapterMode(IntPtr handle, ref AdapterMode mode);
        [DllImport("ndisapi.dll")] private static extern bool SetAdapterMode(IntPtr handle, ref AdapterMode mode);
        [DllImport("ndisapi.dll")] private static extern bool SetPacketEvent(IntPtr handle, IntPtr adapter, IntPtr signal);
        [DllImport("ndisapi.dll")] private static extern bool ReadPacket(IntPtr handle, ref Request request);
        [DllImport("ndisapi.dll")] private static extern bool SendPacketToAdapter(IntPtr handle, ref Request request);
        [DllImport("ndisapi.dll")] private static extern bool SendPacketToMstcp(IntPtr handle, ref Request request);
    }
}
