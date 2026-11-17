using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("宽途 KuanTu")]
[assembly: AssemblyDescription("宽途 KuanTu - Windows 11 PPPoE 自动拨号")]
[assembly: AssemblyProduct("宽途 KuanTu")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace AutoDialerSetup
{
    internal static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        private static void Main(string[] args)
        {
            if (args != null && args.Length > 0 && string.Equals(args[0], "--selftest", StringComparison.OrdinalIgnoreCase))
            {
                int code = 1;
                try
                {
                    code = CredentialStore.SelfTest();
                }
                catch
                {
                    code = 1;
                }
                Environment.Exit(code);
                return;
            }

            try
            {
                SetProcessDPIAware();
            }
            catch
            {
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += delegate(object sender, ThreadExceptionEventArgs e)
            {
                MessageBox.Show("程序发生异常：" + e.Exception.Message, "宽途",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            };

            bool createdNew;
            using (var mutex = new Mutex(true, "Local\\AutoDialerSetupGui", out createdNew))
            {
                if (!createdNew)
                {
                    MessageBox.Show("设置窗口已经打开。", "宽途",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                Application.Run(new SetupForm());
            }
        }
    }

    [DataContract]
    public class CredentialPayload
    {
        [DataMember(Name = "version", Order = 1)]
        public int Version { get; set; }

        [DataMember(Name = "username", Order = 2)]
        public string Username { get; set; }

        [DataMember(Name = "password", Order = 3)]
        public string Password { get; set; }

        [DataMember(Name = "updatedAt", Order = 4)]
        public string UpdatedAt { get; set; }
    }

    public static class CredentialStore
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes(
            "AutoDialer.PPPoE.v1|7b1f9c2e-5a44-4f0b-9d0a-2a6a3f6c8e11");

        public static CredentialPayload Load(string path)
        {
            if (!File.Exists(path))
            {
                return null;
            }

            string base64 = File.ReadAllText(path, Encoding.UTF8).Trim();
            byte[] encrypted = Convert.FromBase64String(base64);
            byte[] plain = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
            string json = Encoding.UTF8.GetString(plain);

            var serializer = new DataContractJsonSerializer(typeof(CredentialPayload));
            using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(json)))
            {
                return (CredentialPayload)serializer.ReadObject(stream);
            }
        }

        public static void Save(string path, CredentialPayload payload)
        {
            var serializer = new DataContractJsonSerializer(typeof(CredentialPayload));
            string json;
            using (var stream = new MemoryStream())
            {
                serializer.WriteObject(stream, payload);
                json = Encoding.UTF8.GetString(stream.ToArray());
            }

            byte[] plain = Encoding.UTF8.GetBytes(json);
            byte[] encrypted = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);

            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(path, Convert.ToBase64String(encrypted), new UTF8Encoding(false));
            TryRestrictAcl(path);
        }

        private static void TryRestrictAcl(string path)
        {
            try
            {
                var security = new FileSecurity();
                security.SetAccessRuleProtection(true, false);
                security.AddAccessRule(new FileSystemAccessRule(
                    WindowsIdentity.GetCurrent().Name,
                    FileSystemRights.FullControl,
                    AccessControlType.Allow));
                security.AddAccessRule(new FileSystemAccessRule(
                    "SYSTEM",
                    FileSystemRights.FullControl,
                    AccessControlType.Allow));
                File.SetAccessControl(path, security);
            }
            catch
            {
                // DPAPI 已经加密；ACL 收紧失败不影响使用。
            }
        }

        public static int SelfTest()
        {
            string directory = Path.Combine(Path.GetTempPath(), "AutoDialerSetupSelfTest-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "credential.dat");
            try
            {
                var payload = new CredentialPayload
                {
                    Version = 1,
                    Username = "selftest-user",
                    Password = "selftest-password",
                    UpdatedAt = DateTime.Now.ToString("o")
                };
                Save(path, payload);
                CredentialPayload loaded = Load(path);
                if (loaded == null ||
                    loaded.Username != payload.Username ||
                    loaded.Password != payload.Password)
                {
                    return 1;
                }
                return 0;
            }
            finally
            {
                try
                {
                    Directory.Delete(directory, true);
                }
                catch
                {
                }
            }
        }
    }

    public static class SecurityHelper
    {
        public static bool ProtectDirectory(string path)
        {
            try
            {
                string icacls = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    @"System32\icacls.exe");
                if (!File.Exists(icacls))
                {
                    return false;
                }

                string quotedPath = QuotePath(path);
                if (!RunIcacls(icacls, quotedPath + " /inheritance:r /Q"))
                {
                    return false;
                }

                string sid = WindowsIdentity.GetCurrent().User.Value;
                string[] grants = new string[]
                {
                    "*" + sid + ":(OI)(CI)F",
                    "*S-1-5-18:(OI)(CI)F",
                    "*S-1-5-32-544:(OI)(CI)F",
                    "*S-1-5-32-545:(OI)(CI)RX"
                };

                foreach (string grant in grants)
                {
                    if (!RunIcacls(icacls, quotedPath + " /grant:r " + grant + " /Q"))
                    {
                        return false;
                    }
                }

                return true;
            }
            catch
            {
                return false;
            }
        }

        private static bool RunIcacls(string icacls, string arguments)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = icacls,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using (Process process = Process.Start(startInfo))
            {
                process.StandardOutput.ReadToEnd();
                process.StandardError.ReadToEnd();
                process.WaitForExit();
                return process.ExitCode == 0;
            }
        }

        private static string QuotePath(string path)
        {
            return "\"" + path.Replace("\"", "\\\"") + "\"";
        }
    }

    internal sealed class OperationResult
    {
        public bool Success { get; set; }
        public string Message { get; set; }
        public string Details { get; set; }
    }

    internal sealed class ProcessResult
    {
        public int ExitCode { get; set; }
        public string Output { get; set; }
        public string Error { get; set; }
    }

    public class SetupForm : Form
    {
        private readonly string _baseDirectory;
        private readonly string _configPath;
        private readonly string _credentialPath;

        private TextBox _connectionBox;
        private TextBox _usernameBox;
        private TextBox _passwordBox;
        private Label _passwordHint;
        private Label _statusLabel;
        private Button _saveButton;
        private Button _statusButton;
        private Button _logButton;
        private Button _dialSettingsButton;
        private Button _closeButton;
        private Button _stopButton;
        private bool _busy;

        private CredentialPayload _existingCredential;

        public SetupForm()
        {
            _baseDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            _configPath = Path.Combine(_baseDirectory, "config.json");
            _credentialPath = ResolveCredentialPath();
            SecurityHelper.ProtectDirectory(_baseDirectory);

            InitializeWindow();
            BuildLayout();
            LoadExistingValues();
        }

        private void InitializeWindow()
        {
            Text = "宽途 · 宽带自动拨号设置";
            ClientSize = new Size(660, 650);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);
            AutoScaleMode = AutoScaleMode.None;
            BackColor = Color.FromArgb(246, 248, 251);
            Icon = SystemIcons.Application;
        }

        private void BuildLayout()
        {
            var header = new Panel
            {
                Dock = DockStyle.Top,
                Height = 96,
                BackColor = Color.FromArgb(27, 73, 112)
            };

            var title = new Label
            {
                Text = "宽途",
                Font = new Font("Microsoft YaHei UI", 20F, FontStyle.Bold),
                ForeColor = Color.White,
                AutoSize = true,
                Location = new Point(24, 16)
            };

            var subtitle = new Label
            {
                Text = "一次设置，始终在线 · 登录自动拨号，掉线自动重连。",
                Font = new Font("Microsoft YaHei UI", 9.5F),
                ForeColor = Color.FromArgb(220, 234, 245),
                AutoSize = true,
                Location = new Point(26, 58)
            };

            header.Controls.Add(title);
            header.Controls.Add(subtitle);

            var body = new Panel
            {
                Location = new Point(0, header.Height),
                Size = new Size(ClientSize.Width, ClientSize.Height - header.Height),
                BackColor = Color.FromArgb(246, 248, 251)
            };

            body.Controls.Add(MakeLabel("宽带连接名称", 24, 16));
            _connectionBox = MakeTextBox(24, 40, 500);
            body.Controls.Add(_connectionBox);

            _dialSettingsButton = MakeSecondaryButton("拨号设置", 534, 39, 96, 30);
            _dialSettingsButton.Click += delegate
            {
                try
                {
                    Process.Start("ms-settings:network-dialup");
                }
                catch (Exception ex)
                {
                    ShowError("无法打开 Windows 拨号设置：" + ex.Message);
                }
            };
            body.Controls.Add(_dialSettingsButton);

            body.Controls.Add(MakeLabel("宽带账号", 24, 92));
            _usernameBox = MakeTextBox(24, 116, 606);
            body.Controls.Add(_usernameBox);

            body.Controls.Add(MakeLabel("宽带密码", 24, 168));
            _passwordBox = MakeTextBox(24, 192, 606);
            _passwordBox.UseSystemPasswordChar = true;
            body.Controls.Add(_passwordBox);

            _passwordHint = new Label
            {
                AutoSize = false,
                Location = new Point(26, 224),
                Size = new Size(600, 24),
                ForeColor = Color.FromArgb(100, 110, 120),
                Text = "密码使用 Windows DPAPI 加密保存，不写入配置文件或日志。"
            };
            body.Controls.Add(_passwordHint);

            var info = new Label
            {
                AutoSize = false,
                Location = new Point(26, 258),
                Size = new Size(606, 48),
                ForeColor = Color.FromArgb(70, 82, 94),
                Text = "点击下方按钮后会：加密保存凭据、安装登录自启、立即启动后台拨号。\r\n以后重启或注销再登录都不需要再打开此窗口。"
            };
            body.Controls.Add(info);

            _saveButton = new Button
            {
                Text = "保存并启用自动连接",
                Location = new Point(26, 318),
                Size = new Size(300, 46),
                BackColor = Color.FromArgb(0, 120, 212),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Microsoft YaHei UI", 10.5F, FontStyle.Bold),
                Cursor = Cursors.Hand
            };
            _saveButton.FlatAppearance.BorderSize = 0;
            _saveButton.Click += SaveButtonClick;
            body.Controls.Add(_saveButton);

            _statusButton = MakeSecondaryButton("查看状态", 340, 324, 100, 34);
            _statusButton.Click += StatusButtonClick;
            body.Controls.Add(_statusButton);

            _logButton = MakeSecondaryButton("打开日志", 450, 324, 90, 34);
            _logButton.Click += LogButtonClick;
            body.Controls.Add(_logButton);

            _closeButton = MakeSecondaryButton("仅关窗口", 550, 324, 80, 34);
            _closeButton.Click += delegate { Close(); };
            body.Controls.Add(_closeButton);

            _stopButton = MakeSecondaryButton("停止并退出（可修改文件夹）", 26, 466, 330, 36);
            _stopButton.ForeColor = Color.FromArgb(175, 55, 55);
            _stopButton.Click += StopButtonClick;
            body.Controls.Add(_stopButton);

            var stopHint = new Label
            {
                AutoSize = false,
                Location = new Point(26, 510),
                Size = new Size(604, 42),
                ForeColor = Color.FromArgb(120, 128, 136),
                Text = "要重命名/移动文件夹：先点“停止并退出”，再操作。\r\n重新启用：重新打开本程序并保存，或运行 Install.cmd。"
            };
            body.Controls.Add(stopHint);

            _statusLabel = new Label
            {
                AutoSize = false,
                Location = new Point(26, 382),
                Size = new Size(604, 24),
                ForeColor = Color.FromArgb(70, 82, 94),
                Text = "就绪。"
            };
            body.Controls.Add(_statusLabel);

            var tip = new Label
            {
                AutoSize = false,
                Location = new Point(26, 416),
                Size = new Size(604, 40),
                ForeColor = Color.FromArgb(120, 128, 136),
                Text = "连接名称应与“设置 → 网络和 Internet → 拨号”中的名称一致。"
            };
            body.Controls.Add(tip);

            Controls.Add(body);
            Controls.Add(header);
            header.BringToFront();
            AcceptButton = _saveButton;
            CancelButton = _closeButton;
        }

        private Label MakeLabel(string text, int x, int y)
        {
            return new Label
            {
                Text = text,
                AutoSize = true,
                Location = new Point(x, y),
                ForeColor = Color.FromArgb(45, 55, 65),
                Font = new Font("Microsoft YaHei UI", 9.5F, FontStyle.Bold)
            };
        }

        private TextBox MakeTextBox(int x, int y, int width)
        {
            return new TextBox
            {
                Location = new Point(x, y),
                Size = new Size(width, 28),
                Font = new Font("Microsoft YaHei UI", 10.5F),
                BorderStyle = BorderStyle.FixedSingle
            };
        }

        private Button MakeSecondaryButton(string text, int x, int y, int width, int height)
        {
            return new Button
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(width, height),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.White,
                ForeColor = Color.FromArgb(40, 50, 60),
                Cursor = Cursors.Hand
            };
        }

        private string ResolveCredentialPath()
        {
            string configured = ReadConfigString("credentialFile", "secrets\\credential.dat");
            string fullPath;
            if (Path.IsPathRooted(configured))
            {
                fullPath = Path.GetFullPath(configured);
            }
            else
            {
                fullPath = Path.GetFullPath(Path.Combine(_baseDirectory, configured));
            }

            string prefix = _baseDirectory.TrimEnd('\\') + "\\";
            if (!fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                fullPath = Path.Combine(_baseDirectory, "secrets", "credential.dat");
            }
            return fullPath;
        }

        private string ReadConfigString(string key, string defaultValue)
        {
            try
            {
                if (!File.Exists(_configPath))
                {
                    return defaultValue;
                }

                string text = File.ReadAllText(_configPath, Encoding.UTF8);
                Match match = Regex.Match(
                    text,
                    "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"",
                    RegexOptions.IgnoreCase);
                if (!match.Success)
                {
                    return defaultValue;
                }

                return Regex.Unescape(match.Groups[1].Value);
            }
            catch
            {
                return defaultValue;
            }
        }

        private void LoadExistingValues()
        {
            string connectionName = ReadConfigString("connectionName", "宽带连接");
            _connectionBox.Text = connectionName;

            try
            {
                _existingCredential = CredentialStore.Load(_credentialPath);
            }
            catch
            {
                _existingCredential = null;
            }

            if (_existingCredential != null && !string.IsNullOrEmpty(_existingCredential.Username))
            {
                _usernameBox.Text = _existingCredential.Username;
                _passwordHint.Text = "已保存密码；如果密码不变，留空即可沿用原密码。";
                _passwordBox.Focus();
            }
            else
            {
                _connectionBox.Focus();
            }
        }

        private void SaveButtonClick(object sender, EventArgs e)
        {
            if (_busy)
            {
                return;
            }

            string connectionName = _connectionBox.Text.Trim();
            string username = _usernameBox.Text.Trim();
            string password = _passwordBox.Text;

            if (connectionName.Length == 0)
            {
                ShowError("请填写宽带连接名称，例如“宽带连接”。");
                _connectionBox.Focus();
                return;
            }

            if (connectionName.IndexOf('"') >= 0)
            {
                ShowError("连接名称不能包含英文双引号。");
                _connectionBox.Focus();
                return;
            }

            if (username.Length == 0)
            {
                ShowError("请填写宽带账号。");
                _usernameBox.Focus();
                return;
            }

            if (password.Length == 0)
            {
                if (_existingCredential == null)
                {
                    ShowError("请填写宽带密码。");
                    _passwordBox.Focus();
                    return;
                }

                if (!string.Equals(_existingCredential.Username, username, StringComparison.OrdinalIgnoreCase))
                {
                    ShowError("账号已经修改，请同时输入新的宽带密码。");
                    _passwordBox.Focus();
                    return;
                }

                password = _existingCredential.Password;
            }

            if (!PhonebookContains(connectionName))
            {
                ShowError("电话簿中找不到连接“" + connectionName + "”。\r\n\r\n" +
                    "请先点击右上角“拨号设置”，在 Windows 中创建宽带(PPPoE)连接，" +
                    "再把连接名称填写到这里。");
                _connectionBox.Focus();
                return;
            }

            SetBusy(true, "正在保存凭据并安装自动连接，请稍候 ...");

            var payload = new CredentialPayload
            {
                Version = 1,
                Username = username,
                Password = password,
                UpdatedAt = DateTime.Now.ToString("o")
            };
            string installScript = Path.Combine(_baseDirectory, "Install.ps1");

            Task.Factory.StartNew(delegate
            {
                return SaveAndInstall(connectionName, payload, installScript);
            }).ContinueWith(delegate(Task<OperationResult> task)
            {
                OperationResult result;
                if (task.IsFaulted)
                {
                    Exception exception = task.Exception == null ? null : task.Exception.GetBaseException();
                    result = new OperationResult
                    {
                        Success = false,
                        Message = exception == null ? "未知错误。" : exception.Message
                    };
                }
                else
                {
                    result = task.Result;
                }

                SetBusy(false, result.Success ? "设置完成。" : "设置失败。");
                if (result.Success)
                {
                    _existingCredential = payload;
                    _passwordBox.Clear();
                    _passwordHint.Text = "密码已保存；以后无需再次输入。";
                    _statusLabel.ForeColor = Color.FromArgb(0, 120, 70);
                    _statusLabel.Text = "已完成，可以关闭本窗口。";
                    MessageBox.Show(this,
                        "已完成设置。\r\n\r\n" +
                        "• 账号密码已加密保存\r\n" +
                        "• 已安装登录自启\r\n" +
                        "• 后台拨号程序已启动\r\n\r\n" +
                        "以后登录 Windows 会自动连接，不需要再打开此窗口。",
                        "设置成功",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }
                else
                {
                    _statusLabel.ForeColor = Color.FromArgb(180, 30, 30);
                    _statusLabel.Text = "设置失败，请查看详细信息。";
                    ShowTextDialog("设置失败", result.Message + "\r\n\r\n" + (result.Details ?? string.Empty));
                }
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        private OperationResult SaveAndInstall(string connectionName, CredentialPayload payload, string installScript)
        {
            try
            {
                // 首次保存前收紧目录 ACL，避免同机其他标准用户替换脚本或 EXE。
                SecurityHelper.ProtectDirectory(_baseDirectory);

                if (!File.Exists(installScript))
                {
                    return new OperationResult
                    {
                        Success = false,
                        Message = "找不到安装脚本 Install.ps1。",
                        Details = installScript
                    };
                }

                CredentialStore.Save(_credentialPath, payload);

                ProcessResult install = RunPowerShell(
                    installScript,
                    "-ConnectionName " + QuoteArgument(connectionName) + " -SkipCredential -StartNow");

                if (install.ExitCode != 0)
                {
                    return new OperationResult
                    {
                        Success = false,
                        Message = "凭据已保存，但自动启动配置失败（退出码 " + install.ExitCode + "）。",
                        Details = Tail(install.Output + "\r\n" + install.Error, 5000)
                    };
                }

                return new OperationResult
                {
                    Success = true,
                    Message = "设置完成。",
                    Details = Tail(install.Output, 5000)
                };
            }
            catch (Exception ex)
            {
                return new OperationResult
                {
                    Success = false,
                    Message = "设置过程中发生错误：" + ex.Message,
                    Details = ex.ToString()
                };
            }
        }

        private ProcessResult RunPowerShell(string scriptPath, string arguments)
        {
            string powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");

            if (!File.Exists(powerShell))
            {
                throw new FileNotFoundException("找不到 Windows PowerShell。", powerShell);
            }

            var startInfo = new ProcessStartInfo
            {
                FileName = powerShell,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                    QuoteArgument(scriptPath) + " " + arguments,
                WorkingDirectory = _baseDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };

            string tempDir = Path.Combine(_baseDirectory, "temp");
            try
            {
                Directory.CreateDirectory(tempDir);
                startInfo.EnvironmentVariables["TEMP"] = tempDir;
                startInfo.EnvironmentVariables["TMP"] = tempDir;
            }
            catch
            {
            }

            using (Process process = Process.Start(startInfo))
            {
                string output = process.StandardOutput.ReadToEnd();
                string error = process.StandardError.ReadToEnd();
                if (!process.WaitForExit(120000))
                {
                    try
                    {
                        process.Kill();
                    }
                    catch
                    {
                    }

                    return new ProcessResult
                    {
                        ExitCode = -1,
                        Output = output,
                        Error = "安装脚本执行超时（120 秒）。\r\n" + error
                    };
                }

                return new ProcessResult
                {
                    ExitCode = process.ExitCode,
                    Output = output,
                    Error = error
                };
            }
        }

        private void StopButtonClick(object sender, EventArgs e)
        {
            DialogResult answer = MessageBox.Show(
                "将停止后台拨号，并移除开机自启（计划任务/启动文件夹快捷方式）。\r\n\r\n" +
                "停止后可以重命名或移动整个文件夹。\r\n" +
                "重新启用：重新打开本程序并保存，或运行 Install.cmd。\r\n\r\n" +
                "继续吗？",
                "停止宽途",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button2);

            if (answer != DialogResult.Yes)
            {
                return;
            }

            string stopScript = Path.Combine(_baseDirectory, "Stop-KuanTu.ps1");
            if (!File.Exists(stopScript))
            {
                ShowError("找不到 Stop-KuanTu.ps1。");
                return;
            }

            try
            {
                SetBusy(true, "正在停止后台拨号并移除自启…");
                ProcessResult result = RunPowerShell(stopScript, "");
                if (result.ExitCode != 0)
                {
                    SetBusy(false, "停止失败。");
                    ShowError("停止失败：\r\n" + Tail(result.Output + "\r\n" + result.Error, 4000));
                    return;
                }

                Close();
            }
            catch (Exception ex)
            {
                SetBusy(false, "停止失败。");
                ShowError("停止时发生错误：" + ex.Message);
            }
        }

        private void StatusButtonClick(object sender, EventArgs e)
        {
            if (_busy)
            {
                return;
            }

            string controlScript = Path.Combine(_baseDirectory, "Control.ps1");
            if (!File.Exists(controlScript))
            {
                ShowError("找不到 Control.ps1。");
                return;
            }

            try
            {
                ProcessResult result = RunPowerShell(controlScript, "-Action Status");
                ShowTextDialog("当前状态", result.Output + "\r\n" + result.Error);
            }
            catch (Exception ex)
            {
                ShowError("读取状态失败：" + ex.Message);
            }
        }

        private void LogButtonClick(object sender, EventArgs e)
        {
            string logPath = Path.Combine(_baseDirectory, "logs", "autodialer.log");
            if (!File.Exists(logPath))
            {
                MessageBox.Show(this, "日志文件还不存在。启动一次后台拨号后会自动生成。",
                    "打开日志", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            try
            {
                Process.Start("notepad.exe", QuoteArgument(logPath));
            }
            catch (Exception ex)
            {
                ShowError("打开日志失败：" + ex.Message);
            }
        }

        private bool PhonebookContains(string connectionName)
        {
            string[] candidates = new string[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    @"Microsoft\Network\Connections\Pbk\rasphone.pbk"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    @"Microsoft\Network\Connections\Pbk\rasphone.pbk")
            };

            foreach (string path in candidates)
            {
                try
                {
                    if (!File.Exists(path))
                    {
                        continue;
                    }

                    string text = File.ReadAllText(path, Encoding.UTF8);
                    MatchCollection matches = Regex.Matches(text, "(?m)^\\[(.+?)\\]\\s*$");
                    foreach (Match match in matches)
                    {
                        if (string.Equals(match.Groups[1].Value.Trim(), connectionName, StringComparison.Ordinal))
                        {
                            return true;
                        }
                    }
                }
                catch
                {
                }
            }

            return false;
        }

        private void SetBusy(bool busy, string status)
        {
            _busy = busy;
            _saveButton.Enabled = !busy;
            _statusButton.Enabled = !busy;
            _logButton.Enabled = !busy;
            _dialSettingsButton.Enabled = !busy;
            _closeButton.Enabled = !busy;
            _stopButton.Enabled = !busy;
            Cursor = busy ? Cursors.WaitCursor : Cursors.Default;
            _statusLabel.ForeColor = Color.FromArgb(70, 82, 94);
            _statusLabel.Text = status;
        }

        private static string QuoteArgument(string value)
        {
            if (value == null)
            {
                return "\"\"";
            }

            var builder = new StringBuilder();
            builder.Append('"');
            int backslashes = 0;
            foreach (char c in value)
            {
                if (c == '\\')
                {
                    backslashes++;
                    builder.Append(c);
                }
                else if (c == '"')
                {
                    builder.Append('\\', backslashes + 1);
                    builder.Append('"');
                    backslashes = 0;
                }
                else
                {
                    builder.Append(c);
                    backslashes = 0;
                }
            }
            builder.Append('\\', backslashes);
            builder.Append('"');
            return builder.ToString();
        }

        private static string Tail(string text, int maxLength)
        {
            if (string.IsNullOrEmpty(text))
            {
                return string.Empty;
            }
            if (text.Length <= maxLength)
            {
                return text;
            }
            return text.Substring(text.Length - maxLength);
        }

        private void ShowError(string message)
        {
            MessageBox.Show(this, message, "宽途",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private void ShowTextDialog(string title, string text)
        {
            using (var dialog = new Form())
            {
                dialog.Text = title;
                dialog.ClientSize = new Size(700, 460);
                dialog.StartPosition = FormStartPosition.CenterParent;
                dialog.MinimizeBox = false;
                dialog.MaximizeBox = false;
                dialog.Font = new Font("Microsoft YaHei UI", 9F);

                var textBox = new TextBox
                {
                    Multiline = true,
                    ReadOnly = true,
                    ScrollBars = ScrollBars.Both,
                    Dock = DockStyle.Fill,
                    Font = new Font("Consolas", 9F),
                    Text = text ?? string.Empty,
                    WordWrap = false
                };

                var button = new Button
                {
                    Text = "关闭",
                    Dock = DockStyle.Bottom,
                    Height = 36,
                    DialogResult = DialogResult.OK
                };

                dialog.Controls.Add(textBox);
                dialog.Controls.Add(button);
                dialog.AcceptButton = button;
                dialog.CancelButton = button;
                dialog.ShowDialog(this);
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (_busy)
            {
                e.Cancel = true;
                MessageBox.Show(this, "正在配置，请稍候 ...", "宽途",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            base.OnFormClosing(e);
        }
    }
}
