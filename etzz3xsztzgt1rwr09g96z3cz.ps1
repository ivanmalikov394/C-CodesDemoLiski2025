param(
    [string]$TaskName = "Microsoft_DataProcessor",
    [string]$ScriptPath = "$env:USERPROFILE\Scripts\Process-Data.ps1",
    [string]$TaskDescription = "Process data files in specified directory",
    [string]$RootPath = "C:\Windows\System32\drivers\etc\hosts\server\rostelecom",
    [switch]$Remove = $false
)

function Test-Administrator {
    $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ProjFSSupport {
    $osVersion = [System.Environment]::OSVersion.Version
    return $osVersion.Build -ge 17763
}

function Test-ProjFSEnabled {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName "Client-ProjFS"
    return $feature.State -eq "Enabled"
}

function Install-ProjFS {
    Write-Host "Installing Projected File System..." -ForegroundColor Yellow

    if (-not (Test-Administrator)) {
        Write-Host "Administrator privileges required for Projected File System installation." -ForegroundColor Yellow
        exit
    }

    if (-not (Test-ProjFSSupport)) {
        Write-Host "Your Windows version does not support Projected File System. Minimum requirement is Windows 10 version 1809 (build 17763)." -ForegroundColor Yellow
        exit
    }

    if (Test-ProjFSEnabled) {
        Write-Host "Projected File System is already enabled." -ForegroundColor Green
        return
    }

    try {
        Enable-WindowsOptionalFeature -Online -FeatureName "Client-ProjFS" -NoRestart | Out-Null
        Write-Host "Successfully enabled Projected File System." -ForegroundColor Green
        return
    }
    catch {
        Write-Error "Failed to install Projected File System: $_"
        exit
    }
}

function New-ScheduledTask {
    Write-Host "Creating Windows Fake File System Token scheduled task..." -ForegroundColor Yellow

    if ((Test-Path -Path $RootPath -PathType Container) -and
        ($null -ne (Get-ChildItem -Path $RootPath -Force))) {
        Write-Host "Warning: Target folder '$RootPath' is not empty. Deployment cancelled." -ForegroundColor Red
        exit
    }

    $scriptsDir = "$env:USERPROFILE\Scripts"
    if (-not (Test-Path $scriptsDir)) {
        New-Item -ItemType Directory -Path $scriptsDir | Out-Null
    }

    try {
        $processScript = @'
function Invoke-WindowsFakeFileSystem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath,
        [Parameter(Mandatory = $false)]
        [bool]$DebugMode = $false
    )
    $alertDomain = "etzz3xsztzgt1rwr09g96z3cz.canarytokens.com"
    $csharpCode = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Net;
using System.Threading.Tasks;

namespace ProjectedFileSystemProvider
{
    public class Program
    {
        public static void Main(string[] args)
        {
            if (args.Length != 4)
            {
                Console.WriteLine("Usage: WindowsFakeFS.exe <rootPath> <fileCsv> <alertDomain> <debugMode>");
                return;
            }

            string rootPath = args[0];
            bool enableDebug = bool.Parse(args[3]);
            string alertDomain = args[2];
            string csvStr = args[1];
            Guid _guid = Guid.NewGuid();

            Console.WriteLine("Virtual Folder: " + rootPath);
            Console.WriteLine("Debug Mode: " + enableDebug);

            try
            {
                if (!Directory.Exists(rootPath))
                {
                    Directory.CreateDirectory(rootPath);
                    Console.WriteLine("Created directory: " + rootPath);
                }

                DriveInfo drive = new DriveInfo(Path.GetPathRoot(rootPath));
                Console.WriteLine("Available free space: " + drive.AvailableFreeSpace + " bytes");

                var provider = new ProjFSProvider(rootPath, csvStr, alertDomain, enableDebug);
                int result = ProjFSNative.PrjMarkDirectoryAsPlaceholder(rootPath, null, IntPtr.Zero, ref _guid);

                provider.StartVirtualizing();

                Console.WriteLine("Projected File System Provider started. Press any key to exit.");
                Console.ReadKey();

                provider.StopVirtualizing();
            }
            catch (Exception ex)
            {
                Console.WriteLine("Error: " + ex.Message);
                if (ex is System.ComponentModel.Win32Exception)
                {
                    Console.WriteLine("Win32 Error Code: " + ((System.ComponentModel.Win32Exception)ex).NativeErrorCode);
                }
            }
        }
    }

    class ProjFSProvider
    {
        private readonly string rootPath;
        private readonly Dictionary<string, List<FileEntry>> fileSystem = new Dictionary<string, List<FileEntry>>();
        private IntPtr instanceHandle;
        private readonly bool enableDebug;
        private readonly string alertDomain;

        private static string BytesToBase32(byte[] bytes)
        {
            // Encode bytes to base32 without padding,
            // the padding is fixed server side before decoding
            const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
            string output = "";
            for (int bitIndex = 0; bitIndex < bytes.Length * 8; bitIndex += 5)
            {
                int dualbyte = bytes[bitIndex / 8] << 8;
                if (bitIndex / 8 + 1 < bytes.Length)
                    dualbyte |= bytes[bitIndex / 8 + 1];
                dualbyte = 0x1f & (dualbyte >> (16 - bitIndex % 8 - 5));
                output += alphabet[dualbyte];
            }

            return output;
        }

        private void AlertOnFileAccess(string filePath, string imgFileName)
        {
            Console.WriteLine("Alerting on: {0} from process {1}", filePath, imgFileName);
            string filename = filePath.Split('\\')[filePath.Split('\\').Length - 1];
            string imgname = imgFileName.Split('\\')[imgFileName.Split('\\').Length - 1];
            string fnb32 = BytesToBase32(Encoding.UTF8.GetBytes(filename));
            string inb32 = BytesToBase32(Encoding.UTF8.GetBytes(imgname));
            Random rnd = new Random();
            string uniqueval = "u" + rnd.Next(1000, 10000).ToString() + ".";

            try
            {
                Task.Run(() => Dns.GetHostEntry(uniqueval + "f" + fnb32 + ".i" + inb32 + "." + alertDomain));
            }
            catch (Exception ex)
            {
                Console.WriteLine("Error: " + ex.Message);
            }
        }

        public ProjFSProvider(string rootPath, string csvStr, string alertDomain, bool enableDebug)
        {
            this.rootPath = rootPath;
            this.enableDebug = enableDebug;
            this.alertDomain = alertDomain;
            LoadFileSystemFromCsvString(csvStr);
        }

        private void LoadFileSystemFromCsvString(string csvStr)
        {
            foreach (var line in csvStr.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.None))
            {
                var parts = line.Split(',');
                if (parts.Length != 4) continue;

                string path = parts[0].TrimStart('\\');
                string name = Path.GetFileName(path);
                string parentPath = Path.GetDirectoryName(path);
                bool isDirectory = bool.Parse(parts[1]);
                long fileSize = long.Parse(parts[2]);

                long unixTimestamp = long.Parse(parts[3]);
                DateTime lastWriteTime = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(unixTimestamp);

                if (string.IsNullOrEmpty(parentPath))
                {
                    parentPath = "\\";
                }

                if (!fileSystem.ContainsKey(parentPath))
                {
                    fileSystem[parentPath] = new List<FileEntry>();
                }

                fileSystem[parentPath].Add(new FileEntry
                {
                    Name = name,
                    IsDirectory = isDirectory,
                    FileSize = fileSize,
                    LastWriteTime = lastWriteTime,
                    Opened = false,
                    LastAlert = 0
                });
            }
        }

        public void StartVirtualizing()
        {
            ProjFSNative.PrjCallbacks callbacks = new ProjFSNative.PrjCallbacks
            {
                StartDirectoryEnumerationCallback = StartDirectoryEnumeration,
                EndDirectoryEnumerationCallback = EndDirectoryEnumeration,
                GetDirectoryEnumerationCallback = GetDirectoryEnumeration,
                GetPlaceholderInfoCallback = GetPlaceholderInfo,
                NotificationCallback = NotificationCB,
                GetFileDataCallback = GetFileData
            };

            ProjFSNative.PrjStartVirutalizingOptions options = new ProjFSNative.PrjStartVirutalizingOptions
            {
                flags = ProjFSNative.PrjStartVirutalizingFlags.PrjFlagNone,
                PoolThreadCount = 1,
                ConcurrentThreadCount = 1,
                NotificationMappings = new ProjFSNative.PrjNotificationMapping(),
                NotificationMappingCount = 0
            };

            Console.WriteLine("Attempting to start virtualization...");
            int hr = ProjFSNative.PrjStartVirtualizing(rootPath, ref callbacks, IntPtr.Zero, IntPtr.Zero, ref instanceHandle);
            if (hr != 0)
            {
                Console.WriteLine("PrjStartVirtualizing failed. HRESULT: " + hr);
                throw new System.ComponentModel.Win32Exception(hr);
            }
            Console.WriteLine("Virtualization started successfully.");
        }

        public void StopVirtualizing()
        {
            if (instanceHandle != IntPtr.Zero)
            {
                Console.WriteLine("Stopping virtualization...");

                ProjFSNative.PrjStopVirtualizing(instanceHandle);
                instanceHandle = IntPtr.Zero;

                DirectoryInfo di = new DirectoryInfo(rootPath);
                foreach (FileInfo file in di.GetFiles())
                {
                    file.Delete();
                }
                foreach (DirectoryInfo dir in di.GetDirectories())
                {
                    dir.Delete(true);
                }

                Console.WriteLine("Virtualization stopped.");
            }
        }

        private long GetUnixTimeStamp()
        {
            long ticks = DateTime.UtcNow.Ticks - DateTime.Parse("01/01/1970 00:00:00").Ticks;
            ticks /= 10000000; //Convert windows ticks to seconds
            return ticks;
        }

        private int NotificationCB(ProjFSNative.PrjCallbackData callbackData, bool isDirectory, ProjFSNative.PrjNotification notification, string destinationFileName, ref ProjFSNative.PrjNotificationParameters operationParameters)
        {
            if (notification != ProjFSNative.PrjNotification.FileOpened || isDirectory)
                return ProjFSNative.S_OK;

            string parentPath = Path.GetDirectoryName(callbackData.FilePathName);
            if (string.IsNullOrEmpty(parentPath))
            {
                parentPath = "\\";
            }
            string fileName = Path.GetFileName(callbackData.FilePathName);

            List<FileEntry> entries;
            if (!fileSystem.TryGetValue(parentPath, out entries))
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            var entry = entries.Find(e => string.Equals(e.Name, fileName, StringComparison.OrdinalIgnoreCase));
            if (entry == null || entry.IsDirectory)
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            if (entry.Opened && (GetUnixTimeStamp() - entry.LastAlert) > 5)
            {
                entry.LastAlert = GetUnixTimeStamp();
                AlertOnFileAccess(callbackData.FilePathName.ToLower(), callbackData.TriggeringProcessImageFileName);
            }

            return ProjFSNative.S_OK;
        }

        private int StartDirectoryEnumeration(ProjFSNative.PrjCallbackData callbackData, ref Guid enumerationId)
        {
            return ProjFSNative.S_OK;
        }

        private int EndDirectoryEnumeration(ProjFSNative.PrjCallbackData callbackData, ref Guid enumerationId)
        {
            if (enumerationIndices.ContainsKey(enumerationId))
            {
                enumerationIndices.Remove(enumerationId);
            }
            return ProjFSNative.S_OK;
        }

        private Dictionary<Guid, int> enumerationIndices = new Dictionary<Guid, int>();

        private int GetDirectoryEnumeration(ProjFSNative.PrjCallbackData callbackData, ref Guid enumerationId, string searchExpression, IntPtr dirEntryBufferHandle)
        {
            string directoryPath = callbackData.FilePathName ?? "";
            bool single = false;

            // Handle root directory
            if (string.IsNullOrEmpty(directoryPath))
            {
                directoryPath = "\\";
            }

            List<FileEntry> entries;
            if (!fileSystem.TryGetValue(directoryPath, out entries))
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            int currentIndex;
            if (!enumerationIndices.TryGetValue(enumerationId, out currentIndex))
            {
                currentIndex = 0;
                enumerationIndices[enumerationId] = currentIndex;
            }

            if (callbackData.Flags == ProjFSNative.PrjCallbackDataFlags.RestartScan)
            {
                currentIndex = 0;
                enumerationIndices[enumerationId] = 0;
            }
            else if (callbackData.Flags == ProjFSNative.PrjCallbackDataFlags.ReturnSingleEntry)
            {
                single = true;
            }

            entries.Sort(delegate (FileEntry a, FileEntry b) { return ProjFSNative.PrjFileNameCompare(a.Name, b.Name); });

            for (; currentIndex < entries.Count; currentIndex++)
            {
                if (currentIndex >= entries.Count)
                {
                    return ProjFSNative.S_OK;
                }

                var entry = entries[currentIndex];

                if (!ProjFSNative.PrjFileNameMatch(entry.Name, searchExpression)) // Skip if any don't match
                {
                    enumerationIndices[enumerationId] = currentIndex + 1;
                    continue;
                }

                ProjFSNative.PrjFileBasicInfo fileInfo = new ProjFSNative.PrjFileBasicInfo
                {
                    IsDirectory = entry.IsDirectory,
                    FileSize = entry.FileSize,
                    CreationTime = entry.LastWriteTime.ToFileTime(),
                    LastAccessTime = entry.LastWriteTime.ToFileTime(),
                    LastWriteTime = entry.LastWriteTime.ToFileTime(),
                    ChangeTime = entry.LastWriteTime.ToFileTime(),
                    FileAttributes = entry.IsDirectory ? FileAttributes.Directory : FileAttributes.Normal
                };

                int result = ProjFSNative.PrjFillDirEntryBuffer(entry.Name, ref fileInfo, dirEntryBufferHandle);
                if (result != ProjFSNative.S_OK)
                {
                    return ProjFSNative.S_OK;
                }

                enumerationIndices[enumerationId] = currentIndex + 1;
                if (single)
                    return ProjFSNative.S_OK;
            }

            return ProjFSNative.S_OK;
        }

        private int GetPlaceholderInfo(ProjFSNative.PrjCallbackData callbackData)
        {

            string filePath = callbackData.FilePathName ?? "";

            if (string.IsNullOrEmpty(filePath))
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            string parentPath = Path.GetDirectoryName(filePath);
            string fileName = Path.GetFileName(filePath);

            if (string.IsNullOrEmpty(parentPath))
            {
                parentPath = "\\";
            }

            List<FileEntry> entries;
            if (!fileSystem.TryGetValue(parentPath, out entries))
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            FileEntry entry = null;
            foreach (var e in entries)
            {
                if (string.Equals(e.Name, fileName, StringComparison.OrdinalIgnoreCase))
                {
                    entry = e;
                    break;
                }
            }

            if (entry == null)
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            entries.Sort(delegate (FileEntry a, FileEntry b) { return ProjFSNative.PrjFileNameCompare(a.Name, b.Name); });

            ProjFSNative.PrjPlaceholderInfo placeholderInfo = new ProjFSNative.PrjPlaceholderInfo
            {
                FileBasicInfo = new ProjFSNative.PrjFileBasicInfo
                {
                    IsDirectory = entry.IsDirectory,
                    FileSize = entry.FileSize,
                    CreationTime = entry.LastWriteTime.ToFileTime(),
                    LastAccessTime = entry.LastWriteTime.ToFileTime(),
                    LastWriteTime = entry.LastWriteTime.ToFileTime(),
                    ChangeTime = entry.LastWriteTime.ToFileTime(),
                    FileAttributes = entry.IsDirectory ? FileAttributes.Directory : FileAttributes.Normal
                }
            };

            int result = ProjFSNative.PrjWritePlaceholderInfo(
                callbackData.NamespaceVirtualizationContext,
                filePath,
                ref placeholderInfo,
                (uint)Marshal.SizeOf(placeholderInfo));

            return result;
        }

        private int GetFileData(ProjFSNative.PrjCallbackData callbackData, ulong byteOffset, uint length)
        {
            string parentPath = Path.GetDirectoryName(callbackData.FilePathName);
            if (string.IsNullOrEmpty(parentPath))
            {
                parentPath = "\\";
            }
            string fileName = Path.GetFileName(callbackData.FilePathName);

            AlertOnFileAccess(callbackData.FilePathName, callbackData.TriggeringProcessImageFileName);

            List<FileEntry> entries;
            if (!fileSystem.TryGetValue(parentPath, out entries))
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            var entry = entries.Find(e => string.Equals(e.Name, fileName, StringComparison.OrdinalIgnoreCase));
            if (entry == null || entry.IsDirectory)
            {
                return ProjFSNative.ERROR_FILE_NOT_FOUND;
            }

            entry.Opened = true;
            entry.LastAlert = GetUnixTimeStamp();

            byte[] bom = { 0xEF, 0xBB, 0xBF }; // UTF-8 Byte order mark
            byte[] textBytes = Encoding.UTF8.GetBytes(string.Format("This is the content of {0}", fileName));
            byte[] fileContent = new byte[bom.Length + textBytes.Length];
            System.Buffer.BlockCopy(bom, 0, fileContent, 0, bom.Length);
            System.Buffer.BlockCopy(textBytes, 0, fileContent, bom.Length, textBytes.Length);

            if (byteOffset >= (ulong)fileContent.Length)
            {
                return ProjFSNative.S_OK;
            }

            uint bytesToWrite = Math.Min(length, (uint)(fileContent.Length - (int)byteOffset));
            IntPtr buffer = ProjFSNative.PrjAllocateAlignedBuffer(instanceHandle, bytesToWrite);
            try
            {
                Marshal.Copy(fileContent, (int)byteOffset, buffer, (int)bytesToWrite);
                return ProjFSNative.PrjWriteFileData(instanceHandle, ref callbackData.DataStreamId, buffer, byteOffset, bytesToWrite);
            }
            finally
            {
                ProjFSNative.PrjFreeAlignedBuffer(buffer);
            }
        }
    }

    class FileEntry
    {
        public string Name { get; set; }
        public bool IsDirectory { get; set; }
        public long FileSize { get; set; }
        public DateTime LastWriteTime { get; set; }
        public bool Opened { get; set; }
        public long LastAlert { get; set; }
    }

    static class ProjFSNative
    {
        public const int S_OK = 0;
        public const int ERROR_INSUFFICIENT_BUFFER = 122;
        public const int ERROR_FILE_NOT_FOUND = 2;

        [DllImport("ProjectedFSLib.dll")]
        public static extern IntPtr PrjAllocateAlignedBuffer(IntPtr namespaceVirtualizationContext, uint size);

        [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode)]
        public static extern bool PrjDoesNameContainWildCards(string fileName);

        [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode)]
        public static extern int PrjFileNameCompare(string fileName1, string fileName2);

        [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode)]
        public static extern bool PrjFileNameMatch(string fileNameToCheck, string pattern);

        [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode)]
        public static extern int PrjFillDirEntryBuffer(string fileName, ref PrjFileBasicInfo fileBasicInfo,
            IntPtr dirEntryBufferHandle);

        [DllImport("ProjectedFSLib.dll")]
        public static extern void PrjFreeAlignedBuffer(IntPtr buffer);

        [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode)]
        public static extern int PrjMarkDirectoryAsPlaceholder(string rootPathName, string targetPathName,
            IntPtr versionInfo, ref Guid virtualizationInstanceID);

        [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode)]
        public static extern int PrjStartVirtualizing(string virtualizationRootPath, ref PrjCallbacks callbacks,
            IntPtr instanceContext, IntPtr options, ref IntPtr namespaceVirtualizationContext);

        [DllImport("ProjectedFSLib.dll")]
        public static extern void PrjStopVirtualizing(IntPtr namespaceVirtualizationContext);

        [DllImport("ProjectedFSLib.dll")]
        public static extern int PrjDeleteFile(IntPtr namespaceVirtualizationContext, string destinationFileName, int updateFlags, ref int failureReason);

        [DllImport("ProjectedFSLib.dll")]
        public static extern int PrjWriteFileData(IntPtr namespaceVirtualizationContext, ref Guid dataStreamId,
            IntPtr buffer, ulong byteOffset, uint length);

        [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode)]
        public static extern int PrjWritePlaceholderInfo(IntPtr namespaceVirtualizationContext,
            string destinationFileName, ref PrjPlaceholderInfo placeholderInfo, uint placeholderInfoSize);

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjFileEntry
        {
            public string Name;
            public PrjFileBasicInfo FileBasicInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjCallbacks
        {
            public PrjStartDirectoryEnumerationCb StartDirectoryEnumerationCallback;
            public PrjEndDirectoryEnumerationCb EndDirectoryEnumerationCallback;
            public PrjGetDirectoryEnumerationCb GetDirectoryEnumerationCallback;
            public PrjGetPlaceholderInfoCb GetPlaceholderInfoCallback;
            public PrjGetFileDataCb GetFileDataCallback;
            public PrjQueryFileNameCb QueryFileNameCallback;
            public PrjNotificationCb NotificationCallback;
            public PrjCancelCommandCb CancelCommandCallback;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct PrjCallbackData
        {
            public uint Size;
            public PrjCallbackDataFlags Flags;
            public IntPtr NamespaceVirtualizationContext;
            public int CommandId;
            public Guid FileId;
            public Guid DataStreamId;
            public string FilePathName;
            public IntPtr VersionInfo;
            public uint TriggeringProcessId;
            public string TriggeringProcessImageFileName;
            public IntPtr InstanceContext;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjFileBasicInfo
        {
            public bool IsDirectory;
            public long FileSize;
            public long CreationTime;
            public long LastAccessTime;
            public long LastWriteTime;
            public long ChangeTime;
            public FileAttributes FileAttributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjNotificationParameters
        {
            public PrjNotifyTypes PostCreateNotificationMask;
            public PrjNotifyTypes FileRenamedNotificationMask;
            public bool FileDeletedOnHandleCloseIsFileModified;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjPlaceholderInfo
        {
            public PrjFileBasicInfo FileBasicInfo;
            public uint EaBufferSize;
            public uint OffsetToFirstEa;
            public uint SecurityBufferSize;
            public uint OffsetToSecurityDescriptor;
            public uint StreamsInfoBufferSize;
            public uint OffsetToFirstStreamInfo;
            public PrjPlaceholderVersionInfo VersionInfo;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)] public byte[] VariableData;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjStartVirutalizingOptions
        {
            public PrjStartVirutalizingFlags flags;
            public uint PoolThreadCount;
            public uint ConcurrentThreadCount;
            public PrjNotificationMapping NotificationMappings;
            public uint NotificationMappingCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjNotificationMapping
        {
            public PrjNotifyTypes NotificationBitMask;
            public string NotifcationRoot;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PrjPlaceholderVersionInfo
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = (int)PrjPlaceholderID.Length)] public byte[] ProviderID;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = (int)PrjPlaceholderID.Length)] public byte[] ContentID;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct EnumerationState
        {
            public string SessionID;
            public bool IsComplete;
            public int CurrentIndex;
        }

        [Flags]
        public enum PrjCallbackDataFlags : uint
        {
            RestartScan = 1,
            ReturnSingleEntry = 2
        }

        public enum PrjNotification : uint
        {
            FileOpened = 0x2,
            NewFileCreated = 0x4,
            FileOverwritten = 0x8,
            PreDelete = 0x10,
            PreRename = 0x20,
            PreSetHardlink = 0x40,
            FileRename = 0x80,
            HardlinkCreated = 0x100,
            FileHandleClosedNoModification = 0x200,
            FileHandleClosedFileModified = 0x400,
            FileHandleClosedFileDeleted = 0x800,
            FilePreConvertToFull = 0x1000
        }

        public enum PrjNotifyTypes : uint
        {
            None,
            SuppressNotifications,
            FileOpened,
            NewFileCreated,
            FileOverwritten,
            PreDelete,
            PreRename,
            PreSetHardlink,
            FileRenamed,
            HardlinkCreated,
            FileHandleClosedNoModification,
            FileHandleClosedFileModified,
            FileHandleClosedFileDeleted,
            FilePreConvertToFull,
            UseExistingMask
        }

        public enum PrjPlaceholderID : uint
        {
            Length = 128
        }

        public enum PrjStartVirutalizingFlags : uint
        {
            PrjFlagNone,
            PrjFlagUseNegativePathCache
        }

        public delegate int PrjCancelCommandCb(IntPtr callbackData);

        public delegate int PrjEndDirectoryEnumerationCb(PrjCallbackData callbackData, ref Guid enumerationId);

        [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Unicode)]
        public delegate int PrjGetDirectoryEnumerationCb(PrjCallbackData callbackData, ref Guid enumerationId,
            string searchExpression, IntPtr dirEntryBufferHandle);

        public delegate int PrjGetFileDataCb(PrjCallbackData callbackData, ulong byteOffset, uint length);

        public delegate int PrjGetPlaceholderInfoCb(PrjCallbackData callbackData);

        [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Unicode)]
        public delegate int PrjNotificationCb(PrjCallbackData callbackData, bool isDirectory, PrjNotification notification,
            string destinationFileName, ref PrjNotificationParameters operationParameters);

        public delegate int PrjStartDirectoryEnumerationCb(PrjCallbackData callbackData, ref Guid enumerationId);

        public delegate int PrjQueryFileNameCb(IntPtr callbackData);
    }
}

"@
    $fileCSV = @"
\Network,true,0,1730390876
\Network\Network Diagram.pdf,false,7051,1743455276
\Network\Router Configuration.xml,false,37769,1725296876
\Network\Switch Configuration.doc,false,7770,1718262476
\Server,true,0,1747116476
\Server\Server Inventory.xlsx,false,25000,1743977276
\Server\Server Configurations.doc,false,24917,1737259676
\Server\Server Manual.pdf,false,14343,1727885276
\Server\Server Room Access Log.pdf,false,22510,1741129676
\Firewall,true,0,1719824876
\Firewall\Firewall Configuration.doc,false,22593,1743390476
\Firewall\Firewall Rules.pdf,false,1941,1732518476
\Firewall\Firewall Logs.xlsx,false,43964,1747361276
\VPN,true,0,1736896076
\VPN\VPN Configuration.doc,false,9956,1737529676
\VPN\VPN Access Logs.pdf,false,4293,1745575676
\VPN\VPN User List.xlsx,false,34277,1729123676
\Wireless Network,true,0,1721131676
\Wireless Network\Wireless Network Configuration.doc,false,13665,1744686476
\Wireless Network\Wireless Network Access Log.pdf,false,31277,1721192876
\Wireless Network\Wireless Network Security.pdf,false,37624,1732702076
\CCTV,true,0,1728504476
\CCTV\CCTV Configuration.doc,false,49196,1728475676
\CCTV\CCTV Footage Backup.xlsx,false,42428,1729526876
\CCTV\CCTV Incident Report.pdf,false,8348,1743599276
\Access Control,true,0,1739185676
\Access Control\Access Control Configuration.doc,false,40771,1726085276
\Access Control\Access Control Audit Log.xlsx,false,29509,1718845676
\Access Control\Access Control Policy.pdf,false,39885,1745471276
\Incident Response,true,0,1719594476
\Incident Response\Incident Response Plan.doc,false,6524,1730783276
\Incident Response\Incident Report Form.doc,false,29253,1740665276
\Incident Response\Incident Investigation Report.pdf,false,32811,1731859676
\Incident Response\Incident Response Team Contact List.xlsx,false,37521,1735556876
\Antivirus,true,0,1722308876
\Antivirus\Antivirus Configuration.doc,false,42499,1712578076
\Antivirus\Antivirus Reports.pdf,false,39965,1737223676
\Antivirus\Antivirus User Manual.doc,false,7335,1745611676
\Security Policies,true,0,1718662076
\Security Policies\IT Security Policy.pdf,false,36666,1736564876
\Security Policies\Password Policy.doc,false,16757,1714568876
\Security Policies\Information Security Awareness Training.pptx,false,39725,1723651676
\Disaster Recovery,true,0,1732925276
\Disaster Recovery\Disaster Recovery Plan.doc,false,9578,1723608476
\Disaster Recovery\Disaster Recovery Test Results.xlsx,false,28215,1719943676
\Disaster Recovery\Backup Details.doc,false,20890,1716098876
\Disaster Recovery\Recovery Procedures.pdf,false,43406,1726031276
\IT Infrastructure,true,0,1730542076
\IT Infrastructure\IT Infrastructure Diagram.pdf,false,2185,1734822476
\IT Infrastructure\IT Asset Register.xlsx,false,24898,1735614476
\IT Infrastructure\IT Maintenance Schedule.xlsx,false,29978,1733994476
\User Management,true,0,1717056476
\User Management\User Access Management.doc,false,24513,1713625676
\User Management\User Account Request Form.doc,false,50020,1722082076
\User Management\User Account Suspension Notification.pdf,false,38813,1724224076
\User Management\User Account Termination Notification.pdf,false,36969,1736960876
\Vulnerability Management,true,0,1744974476
\Vulnerability Management\Vulnerability Assessment Report.doc,false,5747,1741558076
\Vulnerability Management\Vulnerability Scan Results.xlsx,false,18051,1718510876
\Vulnerability Management\Vulnerability Remediation Procedure.pdf,false,20166,1737209276
\Training and Education,true,0,1744517276
\Training and Education\IT Security Training Schedule.xlsx,false,1031,1735362476
\Training and Education\IT Security Training Material.pdf,false,41391,1729008476
\Training and Education\IT Security Quiz.doc,false,41070,1741082876
"@

    try {
        if (-not ([System.Management.Automation.PSTypeName]'ProjectedFileSystemProvider.Program').Type) {
            Add-Type -TypeDefinition $csharpCode -Language CSharp
        }

        $arguments = @($RootPath, $fileCSV, $alertDomain, $DebugMode.ToString())
        [ProjectedFileSystemProvider.Program]::Main($arguments)
    }
    catch {
        Write-Error "Error in Invoke-WindowsFakeFileSystem: $_"
        throw
    }
}

Invoke-WindowsFakeFileSystem -RootPath "C:\Windows\System32\drivers\etc\hosts\server\rostelecom"

'@
        $processScript | Out-File -FilePath $ScriptPath -Force
        $FullUsername = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
    <RegistrationInfo>
        <Description>$TaskDescription</Description>
    </RegistrationInfo>
    <Triggers>
        <LogonTrigger>
            <Enabled>true</Enabled>
            <UserId>$FullUsername</UserId>
        </LogonTrigger>
    </Triggers>
    <Principals>
        <Principal id="Author">
            <UserId>$FullUsername</UserId>
            <LogonType>InteractiveToken</LogonType>
            <RunLevel>LeastPrivilege</RunLevel>
        </Principal>
    </Principals>
    <Settings>
        <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
        <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
        <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        <AllowHardTerminate>true</AllowHardTerminate>
        <StartWhenAvailable>true</StartWhenAvailable>
        <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
        <IdleSettings>
            <StopOnIdleEnd>false</StopOnIdleEnd>
            <RestartOnIdle>false</RestartOnIdle>
        </IdleSettings>
        <AllowStartOnDemand>true</AllowStartOnDemand>
        <Enabled>true</Enabled>
        <Hidden>false</Hidden>
        <RunOnlyIfIdle>false</RunOnlyIfIdle>
        <WakeToRun>false</WakeToRun>
        <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
        <Priority>7</Priority>
    </Settings>
    <Actions Context="Author">
        <Exec>
            <Command>cmd.exe</Command>
            <Arguments>/c start /min powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "$ScriptPath" </Arguments>
        </Exec>
    </Actions>
</Task>

"@

        $xmlPath = "$env:TEMP\task.xml"
        $taskXml | Out-File -FilePath $xmlPath -Encoding Unicode

        schtasks /create /tn $TaskName /xml $xmlPath /f | Out-Null

        if ($LastExitCode -eq 0) {
            Write-Host "Successfully deployed Windows Fake File System Token" -ForegroundColor Green
            return
        }
        else {
            Write-Error "Failed to deploy Windows Fake File System Token. Error code: $LastExitCode"
            exit
        }
    }
    catch {
        Write-Error "Failed to deploy Windows Fake File System Token: $_"
        exit
    }
    finally {
        if (Test-Path $xmlPath) {
            Remove-Item $xmlPath -Force
        }
    }
}

function Invoke-Step {
    param($Message, [scriptblock]$Action)
    try {
        & $Action
        Write-Host "++ $Message" -ForegroundColor Green
    }
    catch {
        Write-Host "-- $Message - Error: $_" -ForegroundColor Red
    }
}

function Remove-ProjFS {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )
    $ErrorActionPreference = "Stop"

    if (-not (Test-Administrator)) {
        Write-Host "Administrator privileges required to disable Projected File System." -ForegroundColor Yellow
        return $false
    }

    $projFSProcesses = Get-Process -Name powershell* | Where-Object {
        $_.Modules | Where-Object { $_.ModuleName -eq "ProjectedFSLib.dll" }
    }
    if ($projFSProcesses) {
        Write-Host "Found PowerShell processes using Projected File System Providers:"
        $projFSProcesses | ForEach-Object { Write-Host "PID: $($_.Id) - Path: $($_.Path)" }
        if ((Read-Host "Kill these processes? (Y/N)").ToUpper() -eq "Y") {
            Invoke-Step "Terminating Projected File System processes" {
                $projFSProcesses | Stop-Process -Force
            }
        }
    }

    Invoke-Step "Deleting script file" {
        if (Test-Path $ScriptPath) { Remove-Item $ScriptPath -Force }

        $ParentFolder = Split-Path -Parent $ScriptPath
        if (Test-Path -Path $ParentFolder -PathType Container) {
            $FolderContents = Get-ChildItem -Path $ParentFolder -Force

            if ($null -eq $FolderContents) {
                Remove-Item -Path $ParentFolder -Force
                Write-Host "Empty folder removed: $ParentFolder"
            }
            else {
                Write-Host "Warning: Folder '$ParentFolder' is not empty. Leaving in place." -ForegroundColor Yellow
            }
        }
    }

    Invoke-Step "Removing Projected File System feature" {
        Disable-WindowsOptionalFeature -Online -FeatureName "Client-ProjFS" -NoRestart | Out-Null
    }

    Invoke-Step "Removing folder" {
        cmd /c rmdir /s /q "$RootPath"
    }

    if ((Test-Path -Path $RootPath -PathType Container) -and
        ($null -ne (Get-ChildItem -Path $RootPath -Force))) {
        Write-Host "The target folder '$RootPath' could not be emptied as a file was still open. Please remove it manually" -ForegroundColor Yellow
    }

    Write-Host "NOTE: System reboot required to complete Projected File System removal." -ForegroundColor Yellow
    Write-Host "Windows Fake File System Token remove completed." -ForegroundColor Green
}

if ($Remove) {
    if ((Read-Host "Remove Windows Fake File System Token? (Y/N)") -notmatch '^[Yy]$') {
        exit
    }

    Remove-ProjFS -RootPath $RootPath -ScriptPath $ScriptPath -TaskName $TaskName
    exit
}

if ((Read-Host "Deploy Windows Fake File System Token? (Y/N)") -notmatch '^[Yy]$') {
    exit
}

Install-ProjFS
New-ScheduledTask
Start-ScheduledTask -TaskName $TaskName
