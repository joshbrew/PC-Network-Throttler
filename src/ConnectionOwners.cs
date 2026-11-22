using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace PcLimiter
{
    internal unsafe struct Endpoint : IEquatable<Endpoint>
    {
        private readonly ulong first;
        private readonly ulong second;
        private readonly ushort port;
        private readonly bool v6;

        internal Endpoint(byte* address, ushort port, bool v6)
        {
            this.port = port;
            this.v6 = v6;
            first = address == null ? 0 : v6 ? *(ulong*)address : *(uint*)address;
            second = address != null && v6 ? *(ulong*)(address + 8) : 0;
        }

        public bool Equals(Endpoint other)
        {
            return first == other.first && second == other.second && port == other.port && v6 == other.v6;
        }

        public override int GetHashCode()
        {
            unchecked { return ((first.GetHashCode() * 397 ^ second.GetHashCode()) * 397 ^ port) * 397 ^ (v6 ? 1 : 0); }
        }
    }

    internal struct Connection : IEquatable<Connection>
    {
        private readonly Endpoint local;
        private readonly Endpoint remote;
        internal Connection(Endpoint local, Endpoint remote) { this.local = local; this.remote = remote; }
        public bool Equals(Connection other) { return local.Equals(other.local) && remote.Equals(other.remote); }
        public override int GetHashCode() { unchecked { return local.GetHashCode() * 397 ^ remote.GetHashCode(); } }
    }

    internal sealed unsafe class ConnectionOwners
    {
        private readonly Dictionary<Connection, AppRule> tcp = new Dictionary<Connection, AppRule>();
        private readonly Dictionary<Endpoint, AppRule> udp = new Dictionary<Endpoint, AppRule>();

        internal void Refresh(AppRule[] rules)
        {
            var paths = new Dictionary<string, AppRule>(StringComparer.OrdinalIgnoreCase);
            foreach (var rule in rules) if (rule.UploadEnabled || rule.DownloadEnabled) paths[rule.Path] = rule;
            var processes = new Dictionary<int, AppRule>();
            var pathBuffer = new StringBuilder(32768);
            foreach (var process in Process.GetProcesses())
            {
                using (process)
                {
                    AppRule rule;
                    string path = ProcessImage.GetPath(process.Id, pathBuffer);
                    if (path != null && paths.TryGetValue(path, out rule)) processes[process.Id] = rule;
                }
            }

            tcp.Clear();
            udp.Clear();
            ReadTable(2, false, processes);
            ReadTable(23, false, processes);
            ReadTable(2, true, processes);
            ReadTable(23, true, processes);
        }

        internal bool TryFind(byte* frame, int length, bool outbound, out AppRule rule)
        {
            byte* source;
            byte* destination;
            int protocol;
            int transport;
            bool v6;
            rule = null;
            if (!ReadHeaders(frame, length, out source, out destination, out protocol, out transport, out v6)) return true;

            ushort sourcePort = Port(frame + transport);
            ushort destinationPort = Port(frame + transport + 2);
            var local = new Endpoint(outbound ? source : destination, outbound ? sourcePort : destinationPort, v6);
            if (protocol == 6)
            {
                var remote = new Endpoint(outbound ? destination : source, outbound ? destinationPort : sourcePort, v6);
                return tcp.TryGetValue(new Connection(local, remote), out rule);
            }
            return udp.TryGetValue(local, out rule) || udp.TryGetValue(new Endpoint(null, outbound ? sourcePort : destinationPort, v6), out rule);
        }

        private void ReadTable(int family, bool isUdp, Dictionary<int, AppRule> processes)
        {
            bool v6 = family == 23;
            int size = 0;
            Query(IntPtr.Zero, ref size, family, isUdp);
            if (size < 4) return;
            IntPtr table = Marshal.AllocHGlobal(size);
            try
            {
                if (Query(table, ref size, family, isUdp) != 0) return;
                byte* start = (byte*)table.ToPointer();
                int rowSize = isUdp ? (v6 ? 28 : 12) : (v6 ? 56 : 24);
                int count = Math.Min(*(int*)start, (size - 4) / rowSize);
                for (int index = 0; index < count; index++)
                {
                    byte* row = start + 4 + index * rowSize;
                    AppRule rule;
                    processes.TryGetValue(*(int*)(row + rowSize - 4), out rule);
                    if (isUdp)
                    {
                        var endpoint = new Endpoint(row, Port(row + (v6 ? 20 : 4)), v6);
                        AppRule previous;
                        // Reused UDP endpoints can belong to several processes. Skip ambiguous owners.
                        if (udp.TryGetValue(endpoint, out previous) && !ReferenceEquals(rule, previous)) rule = null;
                        udp[endpoint] = rule;
                    }
                    else
                    {
                        var local = new Endpoint(row + (v6 ? 0 : 4), Port(row + (v6 ? 20 : 8)), v6);
                        var remote = new Endpoint(row + (v6 ? 24 : 12), Port(row + (v6 ? 44 : 16)), v6);
                        tcp[new Connection(local, remote)] = rule;
                    }
                }
            }
            finally { Marshal.FreeHGlobal(table); }
        }

        private static ushort Port(byte* bytes) { return (ushort)((bytes[0] << 8) | bytes[1]); }

        private static bool ReadHeaders(byte* frame, int length, out byte* source, out byte* destination,
            out int protocol, out int transport, out bool v6)
        {
            source = destination = null;
            protocol = transport = 0;
            v6 = false;
            if (length < 14) return false;
            int network = 14;
            int type = Port(frame + 12);
            while (type == 0x8100 || type == 0x88a8)
            {
                if (length < network + 4) return false;
                type = Port(frame + network + 2);
                network += 4;
            }

            if (type == 0x0800)
            {
                if (length < network + 20 || (Port(frame + network + 6) & 0x1fff) != 0) return false;
                int headerLength = (frame[network] & 15) * 4;
                if (headerLength < 20) return false;
                protocol = frame[network + 9];
                source = frame + network + 12;
                destination = frame + network + 16;
                transport = network + headerLength;
            }
            else if (type == 0x86dd)
            {
                if (length < network + 40) return false;
                v6 = true;
                protocol = frame[network + 6];
                source = frame + network + 8;
                destination = frame + network + 24;
                transport = network + 40;
                while (protocol == 0 || protocol == 43 || protocol == 44 || protocol == 51 || protocol == 60)
                {
                    if (length < transport + 8) return false;
                    int extensionLength;
                    if (protocol == 44)
                    {
                        if ((Port(frame + transport + 2) & 0xfff8) != 0) return false;
                        extensionLength = 8;
                    }
                    else if (protocol == 51) extensionLength = (frame[transport + 1] + 2) * 4;
                    else extensionLength = (frame[transport + 1] + 1) * 8;
                    protocol = frame[transport];
                    transport += extensionLength;
                }
            }
            return (protocol == 6 || protocol == 17) && length >= transport + 4;
        }

        private static uint Query(IntPtr table, ref int size, int family, bool udp)
        {
            return udp ? GetExtendedUdpTable(table, ref size, false, family, 1, 0)
                       : GetExtendedTcpTable(table, ref size, false, family, 5, 0);
        }

        [DllImport("iphlpapi.dll")]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool ordered, int family, int tableClass, uint reserved);
        [DllImport("iphlpapi.dll")]
        private static extern uint GetExtendedUdpTable(IntPtr table, ref int size, bool ordered, int family, int tableClass, uint reserved);
    }
}
