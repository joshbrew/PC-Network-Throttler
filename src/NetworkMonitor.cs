using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace PcLimiter
{
    internal struct TransferBytes
    {
        internal long Sent;
        internal long Received;
    }

    // Reads only the process ID and byte count from Windows TCP and UDP ETW events.
    internal sealed class NetworkMonitor : IDisposable
    {
        private const string SessionName = "NetworkThrottler.AppBandwidth";
        private const uint Stop = 1;
        private readonly object lifecycle = new object();
        private readonly object counters = new object();
        private readonly Thread reader;
        private readonly EventCallback callback;
        private Dictionary<int, TransferBytes> bytes = new Dictionary<int, TransferBytes>();
        private ulong sessionHandle;
        private ulong traceHandle;
        private bool disposed;
        private volatile string status = "Starting live rates";
        private static readonly Guid Tcp = new Guid("9a280ac0-c8e0-11d1-84e2-00c04fb998a2");
        private static readonly Guid Udp = new Guid("bf3a50c5-a9c9-4988-a005-2df0b7c80f80");

        internal NetworkMonitor()
        {
            callback = CountEvent;
            reader = new Thread(Read) { IsBackground = true, Name = "Network Throttler live rates" };
            reader.Start();
        }

        internal string Status { get { return status; } }

        internal Dictionary<int, TransferBytes> ReadAndReset()
        {
            lock (counters)
            {
                var sample = bytes;
                bytes = new Dictionary<int, TransferBytes>();
                return sample;
            }
        }

        private void Read()
        {
            try
            {
                using (var owner = new Mutex(false, @"Global\NetworkThrottler.AppBandwidth.Owner"))
                {
                    bool acquired;
                    try { acquired = owner.WaitOne(0); }
                    catch (AbandonedMutexException) { acquired = true; }
                    if (!acquired) { status = "Live rates are open in another window"; return; }
                    try { ReadSession(); }
                    finally { owner.ReleaseMutex(); }
                }
            }
            catch (Win32Exception error) { status = "Live rates unavailable: " + error.Message; }
            catch (UnauthorizedAccessException) { status = "Live rates need administrator access"; }
        }

        private void ReadSession()
        {
            ulong consumer = 0;
            IntPtr loggerName = Marshal.StringToHGlobalUni(SessionName);
            try
            {
                lock (lifecycle)
                {
                    if (disposed) return;
                    uint result = StartSession(out sessionHandle);
                    if (result == 183)
                    {
                        // A previous app process can leave its own session behind if forcibly closed.
                        WithProperties(delegate(IntPtr properties) { return ControlTrace(0, SessionName, properties, Stop); });
                        result = StartSession(out sessionHandle);
                    }
                    if (result != 0) { sessionHandle = 0; throw new Win32Exception((int)result); }
                    consumer = OpenConsumer(loggerName);
                    traceHandle = consumer;
                    status = "Live rates on";
                }
                uint completion = ProcessTrace(new[] { consumer }, 1, IntPtr.Zero, IntPtr.Zero);
                lock (lifecycle)
                {
                    if (!disposed) status = completion == 0 ? "Live rates stopped" : "Live rates unavailable: " + new Win32Exception((int)completion).Message;
                }
            }
            finally
            {
                lock (lifecycle) { CloseSession(); }
                Marshal.FreeHGlobal(loggerName);
            }
        }

        private static uint StartSession(out ulong handle)
        {
            ulong value = 0;
            uint result = WithProperties(delegate(IntPtr properties) { return StartTrace(out value, SessionName, properties); });
            handle = value;
            return result;
        }

        private static uint WithProperties(Func<IntPtr, uint> action)
        {
            int headerSize = Marshal.SizeOf(typeof(TraceProperties));
            int length = headerSize + 2 * (SessionName.Length + 1);
            IntPtr pointer = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.Copy(new byte[length], 0, pointer, length);
                var parameters = new TraceProperties
                {
                    Wnode = new WnodeHeader { Size = (uint)length, Guid = Guid.NewGuid(), Clock = 1, Flags = 0x00020000 },
                    BufferKb = 64, MinBuffers = 4, MaxBuffers = 64, FlushSeconds = 1,
                    Mode = 0x02000100, // independent system logger with real-time delivery
                    EnableFlags = 0x10010000, // network TCP/IP, excluding system configuration rundown
                    NameOffset = (uint)headerSize
                };
                Marshal.StructureToPtr(parameters, pointer, false);
                return action(pointer);
            }
            finally { Marshal.FreeHGlobal(pointer); }
        }

        private ulong OpenConsumer(IntPtr name)
        {
            var log = new TraceLog
            {
                LoggerName = name,
                Mode = 0x10000100, // event-record callback and real-time mode
                Callback = Marshal.GetFunctionPointerForDelegate(callback)
            };
            ulong handle = OpenTrace(ref log);
            if (handle == 0 || handle == ulong.MaxValue || (IntPtr.Size == 4 && handle == uint.MaxValue))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return handle;
        }

        private void CountEvent(ref EventRecord record)
        {
            if (record.Header.Version == 0 || record.Length < 8 || record.Data == IntPtr.Zero) return;
            byte opcode = record.Header.Opcode;
            bool sent = opcode == 10 || opcode == 26;
            if (!sent && opcode != 11 && opcode != 27) return;
            if (record.Header.Provider != Tcp && record.Header.Provider != Udp) return;

            int pid = Marshal.ReadInt32(record.Data);
            uint count = unchecked((uint)Marshal.ReadInt32(record.Data, 4));
            if (pid <= 0 || count == 0) return;
            lock (counters)
            {
                TransferBytes total;
                bytes.TryGetValue(pid, out total);
                if (sent) total.Sent += count;
                else total.Received += count;
                bytes[pid] = total;
            }
        }

        private void CloseSession()
        {
            if (sessionHandle != 0)
            {
                WithProperties(delegate(IntPtr properties) { return ControlTrace(sessionHandle, null, properties, Stop); });
                sessionHandle = 0;
            }
            if (traceHandle != 0) { CloseTrace(traceHandle); traceHandle = 0; }
        }

        public void Dispose()
        {
            lock (lifecycle)
            {
                disposed = true;
                CloseSession();
            }
            reader.Join(1000);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WnodeHeader
        {
            public uint Size, ProviderId;
            public ulong HistoricalContext, Timestamp;
            public Guid Guid;
            public uint Clock, Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TraceProperties
        {
            public WnodeHeader Wnode;
            public uint BufferKb, MinBuffers, MaxBuffers, MaximumFileSize, Mode, FlushSeconds, EnableFlags, AgeLimit;
            public uint NumberOfBuffers, FreeBuffers, EventsLost, BuffersWritten, LogBuffersLost, RealtimeBuffersLost;
            public IntPtr LoggerThread;
            public uint FileOffset, NameOffset;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ClassicEvent
        {
            public uint SizeAndFlags, Version, Thread, Process;
            public long Timestamp;
            public Guid Guid;
            public ulong ProcessorTime;
            public uint Instance, ParentInstance;
            public Guid Parent;
            public IntPtr Data;
            public uint Length, Context;
        }

        [StructLayout(LayoutKind.Sequential, Size = 172)]
        private struct TimeZoneBlock { public int Bias; }

        [StructLayout(LayoutKind.Sequential)]
        private struct LogHeader
        {
            public uint BufferSize, Version, ProviderVersion, Processors;
            public long EndTime;
            public uint Resolution, MaxFile, Mode, Written, StartBuffers, PointerSize, EventsLost, CpuSpeed;
            public IntPtr LoggerName, FileName;
            public TimeZoneBlock TimeZone;
            public long BootTime, Frequency, StartTime;
            public uint ReservedFlags, BuffersLost;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TraceLog
        {
            public IntPtr FileName, LoggerName;
            public long CurrentTime;
            public uint BuffersRead, Mode;
            public ClassicEvent CurrentEvent;
            public LogHeader Header;
            public IntPtr BufferCallback;
            public uint BufferSize, Filled, EventsLost;
            public IntPtr Callback;
            public uint IsKernel;
            public IntPtr Context;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct EventHeader
        {
            public ushort Size, Type, Flags, Properties;
            public uint Thread, Process;
            public long Timestamp;
            public Guid Provider;
            public ushort Id;
            public byte Version, Channel, Level, Opcode;
            public ushort Task;
            public ulong Keyword, ProcessorTime;
            public Guid Activity;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct EventRecord
        {
            public EventHeader Header;
            public uint BufferContext;
            public ushort ExtendedCount, Length;
            public IntPtr ExtendedData, Data, Context;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void EventCallback(ref EventRecord record);

        [DllImport("advapi32.dll", EntryPoint = "StartTraceW", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint StartTrace(out ulong handle, string name, IntPtr properties);
        [DllImport("advapi32.dll", EntryPoint = "ControlTraceW", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint ControlTrace(ulong handle, string name, IntPtr properties, uint code);
        [DllImport("advapi32.dll", EntryPoint = "OpenTraceW", ExactSpelling = true, SetLastError = true)]
        private static extern ulong OpenTrace(ref TraceLog log);
        [DllImport("advapi32.dll")]
        private static extern uint ProcessTrace([In] ulong[] handles, uint count, IntPtr start, IntPtr end);
        [DllImport("advapi32.dll")]
        private static extern uint CloseTrace(ulong handle);
    }
}
