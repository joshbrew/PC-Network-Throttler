using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace PcLimiter
{
    public sealed class RunningApp
    {
        internal RunningApp(string path, string name, int count, double upload, double download)
        {
            Path = path; Name = name; Count = count; UploadMbps = upload; DownloadMbps = download;
        }
        public string Path { get; private set; }
        public string Name { get; private set; }
        public int Count { get; private set; }
        public double UploadMbps { get; private set; }
        public double DownloadMbps { get; private set; }
    }

    public sealed class AppSnapshot
    {
        internal AppSnapshot(RunningApp[] apps, string monitorStatus, int catalogVersion)
        { Apps = Array.AsReadOnly(apps); MonitorStatus = monitorStatus; CatalogVersion = catalogVersion; }
        public IList<RunningApp> Apps { get; private set; }
        public string MonitorStatus { get; private set; }
        public int CatalogVersion { get; private set; }
        public bool RatesAvailable { get { return MonitorStatus == "Live rates on"; } }
    }

    public sealed class LiveRate : INotifyPropertyChanged
    {
        private bool available;
        public double Upload { get; private set; }
        public double Download { get; private set; }
        public string UploadText { get { return Format(Upload); } }
        public string DownloadText { get { return Format(Download); } }
        public event PropertyChangedEventHandler PropertyChanged;

        public void Set(bool ready, double upload, double download)
        {
            bool sentChanged = ready != available || upload != Upload;
            bool receivedChanged = ready != available || download != Download;
            available = ready;
            Upload = upload;
            Download = download;
            var handler = PropertyChanged;
            if (handler == null) return;
            if (sentChanged) handler(this, new PropertyChangedEventArgs("UploadText"));
            if (receivedChanged) handler(this, new PropertyChangedEventArgs("DownloadText"));
        }

        private string Format(double rate) { return available ? rate.ToString("0.##", CultureInfo.CurrentCulture) : "-"; }
    }

    public sealed class AppCatalog : IDisposable
    {
        private readonly Timer timer;
        private readonly NetworkMonitor monitor = new NetworkMonitor();
        private readonly Dictionary<string, string> names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private volatile AppSnapshot snapshot = new AppSnapshot(new RunningApp[0], "Starting live rates", 0);
        private Dictionary<int, TransferBytes> previousBytes = new Dictionary<int, TransferBytes>();
        private long previousTime = Stopwatch.GetTimestamp();
        private double previousSeconds;
        private int refreshing;

        public AppCatalog() { timer = new Timer(Refresh, null, 0, 1500); }
        public AppSnapshot Snapshot { get { return snapshot; } }
        public void Dispose() { timer.Dispose(); monitor.Dispose(); }

        private void Refresh(object state)
        {
            if (Interlocked.Exchange(ref refreshing, 1) != 0) return;
            try
            {
                var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                var totals = new Dictionary<string, TransferBytes>(StringComparer.OrdinalIgnoreCase);
                var sample = monitor.ReadAndReset();
                long now = Stopwatch.GetTimestamp();
                double seconds = (now - previousTime) / (double)Stopwatch.Frequency;
                double divisor = Math.Max(1.0, seconds + previousSeconds) * 125000.0;
                string monitorStatus = monitor.Status;
                var pathBuffer = new StringBuilder(32768);
                foreach (Process process in Process.GetProcesses())
                {
                    using (process)
                    {
                        int pid = process.Id;
                        string path = ProcessImage.GetPath(pid, pathBuffer);
                        if (path == null || !String.Equals(Path.GetExtension(path), ".exe", StringComparison.OrdinalIgnoreCase)) continue;
                        int count;
                        counts.TryGetValue(path, out count);
                        counts[path] = count + 1;

                        TransferBytes latest, prior, total;
                        sample.TryGetValue(pid, out latest);
                        previousBytes.TryGetValue(pid, out prior);
                        if (latest.Sent == 0 && latest.Received == 0 && prior.Sent == 0 && prior.Received == 0) continue;
                        totals.TryGetValue(path, out total);
                        total.Sent += latest.Sent + prior.Sent;
                        total.Received += latest.Received + prior.Received;
                        totals[path] = total;
                    }
                }
                previousBytes = sample;
                previousTime = now;
                previousSeconds = seconds;

                var previous = snapshot;
                bool catalogUnchanged = previous.Apps.Count == counts.Count;
                bool ratesUnchanged = monitorStatus == previous.MonitorStatus;
                if (catalogUnchanged)
                {
                    foreach (RunningApp app in previous.Apps)
                    {
                        int count;
                        if (!counts.TryGetValue(app.Path, out count) || count != app.Count) { catalogUnchanged = false; break; }
                        TransferBytes total;
                        totals.TryGetValue(app.Path, out total);
                        if (ToRate(total.Sent, divisor) != app.UploadMbps || ToRate(total.Received, divisor) != app.DownloadMbps)
                            ratesUnchanged = false;
                    }
                    if (catalogUnchanged && ratesUnchanged) return;
                }

                var apps = new RunningApp[counts.Count];
                int index = 0;
                foreach (var entry in counts)
                {
                    string name;
                    if (!names.TryGetValue(entry.Key, out name))
                    {
                        name = FriendlyName(entry.Key);
                        names[entry.Key] = name;
                    }
                    TransferBytes total;
                    totals.TryGetValue(entry.Key, out total);
                    apps[index++] = new RunningApp(entry.Key, name, entry.Value, ToRate(total.Sent, divisor), ToRate(total.Received, divisor));
                }
                snapshot = new AppSnapshot(apps, monitorStatus, previous.CatalogVersion + (catalogUnchanged ? 0 : 1));
            }
            catch (System.ComponentModel.Win32Exception) { /* Keep the last successful snapshot. */ }
            finally { Volatile.Write(ref refreshing, 0); }
        }

        private static double ToRate(long bytes, double divisor) { return Math.Round(bytes / divisor, 2); }

        private static string FriendlyName(string file)
        {
            try
            {
                string name = FileVersionInfo.GetVersionInfo(file).FileDescription;
                if (!String.IsNullOrWhiteSpace(name)) return name.Trim();
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (System.ComponentModel.Win32Exception) { }
            return Path.GetFileName(file);
        }
    }

    internal static class ProcessImage
    {
        internal static string GetPath(int pid, StringBuilder buffer)
        {
            const uint queryLimitedInformation = 0x1000;
            IntPtr handle = OpenProcess(queryLimitedInformation, false, pid);
            if (handle == IntPtr.Zero) return null;
            try
            {
                int length = buffer.Capacity;
                return QueryFullProcessImageName(handle, 0, buffer, ref length) ? buffer.ToString() : null;
            }
            finally { CloseHandle(handle); }
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int length);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
