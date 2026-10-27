using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Drawing;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Collections;
using System.Collections.Generic;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Program {
    internal static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "MAXsGatewaySwitch");
    internal static string Worker { get { return Path.Combine(Root, "NetworkWorker-2.3.1.ps1"); } }
    internal static bool Preview;
    internal static Dictionary<string, object> Map(object o) { return (Dictionary<string, object>)o; }
    internal static string Str(Dictionary<string, object> d, string key) { return d.ContainsKey(key) && d[key] != null ? Convert.ToString(d[key]) : ""; }
    internal static bool Flag(Dictionary<string, object> d, string key) { return d.ContainsKey(key) && d[key] is bool && (bool)d[key]; }
    internal static bool Admin { get { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); } }

    [STAThread] static void Main(string[] args) {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Preview = args.Length > 0 && args[0] == "--render";
        if (Preview) {
            using(var form = new MainForm()) {
                form.LoadPreview(); if(args.Length>2 && args[2]=="auto") form.LoadAutoPreview(); form.Show(); Application.DoEvents();
                using(var bitmap = new Bitmap(form.Width, form.Height)) { form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size)); bitmap.Save(args[1]); }
            }
            return;
        }
        try {
            if (!Admin) {
                var start = new ProcessStartInfo(Application.ExecutablePath) { UseShellExecute=true, Verb="runas", WorkingDirectory=AppDomain.CurrentDomain.BaseDirectory };
                Process.Start(start); return;
            }
            bool created;
            using (var mutex = new Mutex(true, "Global\\MAXsGatewaySwitch-v1", out created)) {
                if (!created) { MessageBox.Show("网络切换工具已经在运行，请使用已打开的窗口。", "网络切换"); return; }
                try {
                    PrepareWorker();
                    Application.Run(new MainForm());
                } finally { mutex.ReleaseMutex(); }
            }
        } catch(Exception ex) { MessageBox.Show(ex.Message, "网络切换工具", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    static void PrepareWorker() {
        var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
        if (Directory.Exists(Root)) {
            var di = new DirectoryInfo(Root);
            if ((di.Attributes & FileAttributes.ReparsePoint) != 0) throw new Exception("备份目录不能是链接。请检查 " + Root);
            var owner = di.GetAccessControl().GetOwner(typeof(SecurityIdentifier));
            if (!owner.Equals(admins) && !owner.Equals(system)) throw new Exception("备份目录权限异常，未加载脚本或修改网络：" + Root);
        }
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false); security.SetOwner(admins);
        foreach(var sid in new[] { admins, system }) security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Directory.CreateDirectory(Root, security); new DirectoryInfo(Root).SetAccessControl(security);
        foreach(string name in new[] { Worker, Path.Combine(Root,"restore.json"), Path.Combine(Root,"restore.tmp") })
            if (File.Exists(name) && (File.GetAttributes(name) & FileAttributes.ReparsePoint) != 0) throw new Exception("备份/脚本文件不能是链接：" + name);
        using(var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("NetworkWorker.ps1"))
        using(var reader = new StreamReader(stream, Encoding.UTF8)) File.WriteAllText(Worker, reader.ReadToEnd(), new UTF8Encoding(true));
    }

    internal static Dictionary<string, object> Run(string mode, string id, int owner=0, long ticks=0) {
        if (!new[] { "Inspect", "Proxy", "Restore", "Repair" }.Contains(mode)) throw new ArgumentException("Invalid mode");
        if (id.Length > 0) id = Guid.Parse(id).ToString();
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if(mode=="Proxy") { var self=Process.GetCurrentProcess();owner=self.Id;ticks=self.StartTime.ToUniversalTime().Ticks; }
        var start = new ProcessStartInfo(ps, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Worker + "\" -Mode " + mode + (id.Length > 0 ? " -AdapterId " + id : "") + " -OwnerProcessId " + owner + " -OwnerStartTicks " + ticks) {
            UseShellExecute=false, CreateNoWindow=true, WindowStyle=ProcessWindowStyle.Hidden,
            RedirectStandardOutput=true, RedirectStandardError=true,
            StandardOutputEncoding=Encoding.UTF8, StandardErrorEncoding=Encoding.UTF8
        };
        using(var p = Process.Start(start)) {
            var stdout = p.StandardOutput.ReadToEndAsync(); var stderr = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(90000)) { try { p.Kill(); } catch {} throw new Exception("操作超时。请点击恢复自动，备份不会被删除。"); }
            string output = stdout.Result.Trim(); string errors = stderr.Result.Trim();
            try { return Map(new JavaScriptSerializer().DeserializeObject(output)); }
            catch { throw new Exception("无法读取网络状态。" + (errors.Length > 0 ? errors : output)); }
        }
    }
}

internal class AdapterChoice {
    internal Dictionary<string,object> Data;
    public override string ToString() { return Program.Str(Data,"Name") + "   ·   " + Program.Str(Data,"Address"); }
}

internal static class Theme {
    internal static Color Bg=ColorTranslator.FromHtml("#0B0A10"), Panel=ColorTranslator.FromHtml("#16141C"), Deep=ColorTranslator.FromHtml("#0F0E14"), Bar=ColorTranslator.FromHtml("#141219"), Line=ColorTranslator.FromHtml("#26222E"), Yellow=ColorTranslator.FromHtml("#FCEE0A"), Cyan=ColorTranslator.FromHtml("#02D7F2"), Pink=ColorTranslator.FromHtml("#FF2A6D"), Text=ColorTranslator.FromHtml("#E8E6EF"), Muted=ColorTranslator.FromHtml("#8D889A");
    internal static Font Font(float size,bool bold=false,bool mono=false) { return new Font(mono?"Consolas":"Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular,GraphicsUnit.Pixel); }
    internal static Point[] Cut(Rectangle r,int c) { return new[]{new Point(r.Left+c,r.Top),new Point(r.Right-1,r.Top),new Point(r.Right-1,r.Bottom-c),new Point(r.Right-c,r.Bottom-1),new Point(r.Left,r.Bottom-1),new Point(r.Left,r.Top+c)}; }
}
internal class CutButton : Button {
    internal Color Accent=Theme.Cyan;
    internal bool Filled;
    bool hover;
    public CutButton(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);FlatStyle=FlatStyle.Flat;Cursor=Cursors.Hand;TabStop=true;AccessibleRole=AccessibleRole.PushButton;Font=Theme.Font(16,true);}
    protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}
    protected override void OnMouseLeave(EventArgs e){hover=false;Invalidate();base.OnMouseLeave(e);}
    protected override void OnPaint(PaintEventArgs e){
        var g=e.Graphics;g.Clear(Theme.Bg);g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        Color a=Enabled||Filled?Accent:Color.FromArgb(83,79,92);
        using(var b=new SolidBrush(a))g.FillPolygon(b,Theme.Cut(ClientRectangle,14));
        var r=ClientRectangle;r.Inflate(-1,-1);
        bool fill=Filled||(Enabled&&hover);
        using(var b=new SolidBrush(fill?a:Theme.Bg))g.FillPolygon(b,Theme.Cut(r,13));
        TextRenderer.DrawText(g,Text,Font,ClientRectangle,fill?Theme.Bg:a,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
        if(Focused)ControlPaint.DrawFocusRectangle(g,new Rectangle(20,8,Width-40,Height-16),a,Theme.Bg);
    }
}
internal class MainForm : Form {
    AdapterSelector adapters;
    CutButton proxy,restore,refresh;
    FlowLayoutPanel log;
    Button minimize, maximize, close;
    bool busy,hasBackup,isActive,loading,exitRequested,restorePending,polling,legacyState,persistentReady;
    int operationRevision;
    string lastPollingError="";
    readonly Func<string,string,Dictionary<string,object>> runOperation;
    NotifyIcon tray;
    System.Windows.Forms.Timer maintenance = new System.Windows.Forms.Timer { Interval=15000 };
    string message="正在读取网卡…", backupAdapter="";
    int logCount;
    Dictionary<string,object> current;
    System.Windows.Forms.ToolTip hints=new System.Windows.Forms.ToolTip();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h,int m,IntPtr w,IntPtr l);
    public MainForm() : this(null) { }
    internal MainForm(Func<string,string,Dictionary<string,object>> runner){
        runOperation=runner??((mode,id)=>Program.Run(mode,id));
        Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);ShowIcon=true;Text="旁路由切换";ClientSize=new Size(900,760);MinimumSize=new Size(900,720);
        FormBorderStyle=FormBorderStyle.None;StartPosition=FormStartPosition.CenterScreen;BackColor=Theme.Bg;ForeColor=Theme.Text;
        Font=Theme.Font(13);AutoScaleMode=AutoScaleMode.None;DoubleBuffered=true;
        adapters=new AdapterSelector();
        adapters.SelectedIndexChanged+=(s,e)=>{UpdateDetails();if(!loading&&current!=null)AddLog("已切换到网卡 "+Program.Str(current,"Name")+"；没有修改网络。","READ");};
        Controls.Add(adapters);
        refresh=MakeButton("刷新  ↻",Theme.Cyan);refresh.Click+=async(s,e)=>await Execute(hasBackup&&!restorePending&&!legacyState?"Repair":"Inspect");
        proxy=MakeButton("01 //   切到旁路由",Theme.Yellow);proxy.Click+=async(s,e)=>await Execute("Proxy");
        restore=MakeButton("02 //   恢复自动",Theme.Cyan);restore.Click+=async(s,e)=>await Execute("Restore");
        log=new FlowLayoutPanel{AutoScroll=true,FlowDirection=FlowDirection.TopDown,WrapContents=false,BackColor=Theme.Deep,AccessibleName="操作记录",Padding=new Padding(0,4,0,0)};Controls.Add(log);        minimize=WindowButton("─");minimize.Click+=(s,e)=>WindowState=FormWindowState.Minimized;
        maximize=WindowButton("□");maximize.Click+=(s,e)=>WindowState=WindowState==FormWindowState.Maximized?FormWindowState.Normal:FormWindowState.Maximized;
        close=WindowButton("×");close.FlatAppearance.MouseOverBackColor=Theme.Pink;close.Click+=(s,e)=>Close();
        Shown+=async(s,e)=>{if(!Program.Preview)await Execute("Inspect");};
        FormClosing+=(s,e)=>{
            if(e.CloseReason!=CloseReason.UserClosing)return;
            if(busy){e.Cancel=true;AddLog("请等待当前操作完成。","WAIT");return;}
            if(hasBackup&&!exitRequested&&!Program.Preview){e.Cancel=true;Hide();tray.Visible=true;tray.ShowBalloonTip(2500,"旁路由状态检查","程序继续只读检查。新版开启的旁路由在重启后也保留；还原请点击恢复自动。",ToolTipIcon.Info);}
        };
        maintenance.Tick+=async(s,e)=>await CheckStatus();
        if(!Program.Preview){
            var menu=new ContextMenuStrip();
            menu.Items.Add("打开窗口",null,(s,e)=>{Show();WindowState=FormWindowState.Normal;Activate();});
            menu.Items.Add("退出（保留当前配置）",null,(s,e)=>{if(busy)return;exitRequested=true;Close();});
            menu.Items.Add("恢复并退出",null,async(s,e)=>{if(busy)return;await Execute("Restore");if(!hasBackup){exitRequested=true;Close();}else{Show();Activate();}});
            tray=new NotifyIcon{Icon=this.Icon??SystemIcons.Application,Text="NetworkSwitch 2.3.1 · 重启保留",ContextMenuStrip=menu,Visible=true};
            tray.DoubleClick+=(s,e)=>{Show();WindowState=FormWindowState.Normal;Activate();};
            maintenance.Start();
        }
        FormClosed+=(s,e)=>{maintenance.Stop();maintenance.Dispose();if(tray!=null){tray.Visible=false;tray.Dispose();}};
        Resize+=(s,e)=>Arrange();
        MouseDown+=(s,e)=>{if(e.Button==MouseButtons.Left&&e.Y<110){ReleaseCapture();SendMessage(Handle,0xA1,(IntPtr)2,IntPtr.Zero);}};
        Arrange();
    }
    CutButton MakeButton(string title,Color accent){var b=new CutButton{Text=title,Accent=accent,AccessibleName=title};Controls.Add(b);return b;}
    Button WindowButton(string title){var b=new Button{Text=title,FlatStyle=FlatStyle.Flat,BackColor=Theme.Bar,ForeColor=Theme.Muted,Font=Theme.Font(18),TabStop=true};b.FlatAppearance.BorderSize=0;b.FlatAppearance.MouseOverBackColor=Theme.Line;Controls.Add(b);return b;}
    void Arrange(){int w=ClientSize.Width,h=ClientSize.Height;
        adapters.SetBounds(28,181,w-200,40);refresh.SetBounds(w-158,181,130,40);
        proxy.SetBounds(28,380,(w-68)/2,52);restore.SetBounds(40+(w-68)/2,380,(w-68)/2,52);
        log.SetBounds(41,531,w-82,Math.Max(120,h-585));
        minimize.SetBounds(w-132,0,44,32);maximize.SetBounds(w-88,0,44,32);close.SetBounds(w-44,0,44,32);
        Invalidate();
    }
    void Box(Graphics g,Color c,int x,int y,int w,int h){using(var b=new SolidBrush(c))g.FillRectangle(b,x,y,w,h);}
    void Txt(Graphics g,string t,float size,Color c,int x,int y,int w,int h,bool bold=false,bool mono=false){using(var f=Theme.Font(size,bold,mono))TextRenderer.DrawText(g,t,f,new Rectangle(x,y,w,h),c,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);}
    void Logo(Graphics g,int x,int y,int size){var state=g.Save();g.TranslateTransform(x,y);g.ScaleTransform(size/48f,size/48f);
        using(var b=new SolidBrush(Theme.Yellow))g.FillPolygon(b,new[]{new Point(0,0),new Point(38,0),new Point(48,10),new Point(48,48),new Point(10,48),new Point(0,38)});
        using(var p=new Pen(Theme.Bg,4)){g.DrawLines(p,new[]{new Point(7,31),new Point(19,31),new Point(27,17),new Point(41,17)});g.DrawLine(p,19,31,41,31);}
        Box(g,Theme.Pink,37,14,6,6);Box(g,Theme.Bg,37,28,6,6);g.Restore(state);
    }
    protected override void OnPaint(PaintEventArgs e){
        base.OnPaint(e);var g=e.Graphics;int w=ClientSize.Width,h=ClientSize.Height;Color accent=isActive?Theme.Yellow:Theme.Cyan;
        Box(g,Theme.Bar,0,0,w,32);Logo(g,12,8,16);Txt(g,"旁路由切换",12,Theme.Muted,36,0,200,32);
        Logo(g,28,56,56);Txt(g,"旁路由切换",28,Theme.Text,100,53,230,38,true);using(var titleFont=Theme.Font(28,true)){int vx=100+TextRenderer.MeasureText(g,"旁路由切换",titleFont,Size.Empty,TextFormatFlags.NoPadding).Width+12;Txt(g,"v2.3.1",11,Theme.Cyan,vx,70,65,20,false,true);}
        Txt(g,message,12,accent,100,94,w-290,24);
        var tag=new Rectangle(w-163,57,135,27);using(var b=new SolidBrush(accent))g.FillPolygon(b,Theme.Cut(tag,8));
        Txt(g,busy?"NET::BUSY":hasBackup?(isActive?"NET::PROXY":"NET::CHECK"):"NET::READY",12,Theme.Bg,w-153,57,125,27,true,true);
        Txt(g,"IPv6 :: "+(current==null?"--":Program.Flag(current,"IPv6")?"ON":"OFF"),10,Theme.Pink,w-163,89,135,20,false,true);
        for(int x=28;x<w-28;x+=20){using(var b=new SolidBrush(Theme.Yellow))g.FillPolygon(b,new[]{new Point(x,138),new Point(Math.Min(x+10,w-28),138),new Point(Math.Min(x+4,w-28),144),new Point(Math.Max(28,x-6),144)});}
        Txt(g,"网卡 / ADAPTER",11,Theme.Muted,28,155,350,24);Box(g,Theme.Cyan,28,220,w-200,2);
        string[] labels={"IPv4","当前默认网关","DNS","代理入口"}, codes={"ADDR","GW","DNS","PROXY"};
        string[] vals=current==null?new[]{"--","--","--","--"}:new[]{Program.Str(current,"Address"),Program.Str(current,"Gateway"),Program.Str(current,"Dns"),hasBackup?"192.168.1.192":"--"};
        string[] subs={current!=null&&Program.Flag(current,"Dhcp")?"自动获取（DHCP）":"手动 / 未知","DHCP 默认网关","当前解析服务器",hasBackup?(restorePending?"待完成还原":legacyState?"旧版临时配置":isActive?(persistentReady?"已生效 / 重启保留":"当前有效 / 未保存"):"请手动修复或还原"):"未启用"};
        int cw=(w-86)/4;
        for(int i=0;i<4;i++){int x=28+i*(cw+10);Box(g,Theme.Panel,x,238,cw,94);Box(g,i==0?Theme.Cyan:i==3&&!isActive?Theme.Line:Theme.Yellow,x,238,3,94);
            Txt(g,labels[i],13,Theme.Muted,x+13,246,cw-62,21);Txt(g,codes[i],11,Theme.Pink,x+cw-53,247,48,20,true,true);
            Txt(g,string.IsNullOrEmpty(vals[i])?"--":vals[i],23,i==0?Theme.Cyan:i==3?accent:Theme.Text,x+12,271,cw-20,29,true,true);
            Txt(g,subs[i],12,Theme.Muted,x+12,305,cw-20,20);
        }
        Box(g,Theme.Cyan,28,346,w-56,26);Txt(g,"保留 DHCP 网关；使用专用 IPv4 路由与 DNS，IPv6 保持原设置。",11,Theme.Bg,40,346,w-80,26);
        Txt(g,"后台每 15 秒只读检查，不自动切换或改写网络；关闭窗口进入托盘。",11,Theme.Muted,28,444,w-56,22);
        Txt(g,"新版开启后，退出程序和重启电脑都保留旁路由；点击「恢复自动」才还原。",11,Theme.Muted,28,465,w-56,22);
        Box(g,Theme.Line,28,502,w-56,h-544);Box(g,Theme.Deep,29,503,w-58,h-546);Box(g,Theme.Yellow,29,503,w-58,27);
        Txt(g,"操作记录 · LOG",13,Theme.Bg,40,503,230,27,true);Txt(g,"SYS.LOG // "+logCount+" 条",10,Theme.Bg,w-210,503,170,27,true,true);
        Box(g,Theme.Bar,0,h-28,w,28);Txt(g,">>  托盘可退出保留配置，或恢复并退出",11,Theme.Muted,14,h-28,w-310,28);
        Txt(g,"GW "+(current==null?"--":Program.Str(current,"Gateway")),11,Theme.Cyan,w-290,h-28,276,28,false,true);
        using(var p=new Pen(Theme.Line))g.DrawRectangle(p,0,0,w-1,h-1);
    }
    void AddLog(string value,string tag="READ"){
        var row=new TableLayoutPanel{Width=Math.Max(700,log.ClientSize.Width-24),AutoSize=true,ColumnCount=3,BackColor=Theme.Deep,Margin=new Padding(0,0,0,6)};
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,78));row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,48));row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        row.Controls.Add(new Label{Text=DateTime.Now.ToString("HH:mm:ss"),ForeColor=Theme.Pink,Font=Theme.Font(12,false,true),AutoSize=true,Margin=Padding.Empty},0,0);
        row.Controls.Add(new Label{Text=tag,ForeColor=tag=="ERR"||tag=="RST"?Theme.Pink:tag=="READ"?Theme.Cyan:Theme.Yellow,Font=Theme.Font(11,true,true),AutoSize=true,Margin=Padding.Empty},1,0);
        row.Controls.Add(new Label{Text=value,ForeColor=Theme.Text,Font=Theme.Font(12),AutoSize=true,MaximumSize=new Size(row.Width-126,0),Margin=Padding.Empty},2,0);
        log.Controls.Add(row);if(log.Controls.Count>200){var oldRow=log.Controls[0];log.Controls.Remove(oldRow);oldRow.Dispose();}log.ScrollControlIntoView(row);logCount++;Invalidate();
    }    void UpdateDetails(){
        var a=adapters.SelectedItem as AdapterChoice;current=a==null?null:a.Data;
        proxy.Enabled=!busy&&!hasBackup&&current!=null&&Program.Str(current,"Target")=="192.168.1.192"&&Program.Flag(current,"Dhcp");
        restore.Enabled=!busy&&hasBackup;refresh.Enabled=!busy;adapters.Enabled=!busy&&!hasBackup;
        refresh.Text=hasBackup&&!restorePending&&!legacyState?"手动修复":"刷新  ↻";
        hints.SetToolTip(refresh,hasBackup&&!restorePending&&!legacyState?"手动检查并补回当前和重启保留的路由与 DNS；后台不会自动修复":"只读取状态；旧版配置请先恢复自动，再重新开启");
        proxy.Filled=isActive;restore.Filled=!hasBackup;proxy.Invalidate();restore.Invalidate();
        hints.SetToolTip(restore,hasBackup?"恢复网卡 "+backupAdapter+" 的原设置":"没有本工具保存的待还原设置");
        Invalidate();
    }
    void Display(Dictionary<string,object> data){
        hasBackup=Program.Flag(data,"HasBackup");isActive=Program.Flag(data,"Active");restorePending=Program.Flag(data,"RestorePending");backupAdapter=Program.Str(data,"BackupAdapter");
        legacyState=Program.Flag(data,"LegacyState");persistentReady=Program.Flag(data,"PersistentReady");
        string old=current==null?"":Program.Str(current,"Id");loading=true;adapters.Items.Clear();
        var list=data["Adapters"] as object[];if(list!=null)foreach(var item in list)adapters.Items.Add(new AdapterChoice{Data=Program.Map(item)});
        int pick=-1;for(int i=0;i<adapters.Items.Count;i++)if(Program.Str(((AdapterChoice)adapters.Items[i]).Data,"Id")==old)pick=i;
        if(pick<0)for(int i=0;i<adapters.Items.Count;i++)if(Program.Str(((AdapterChoice)adapters.Items[i]).Data,"Target")=="192.168.1.192"){pick=i;break;}
        if(pick<0&&adapters.Items.Count>0)pick=0;adapters.SelectedIndex=pick;loading=false;
        message=hasBackup?(restorePending?"还原未完成 · 请点击恢复自动重试":legacyState?"旧版临时配置 · 请先恢复自动，再重新开启":isActive?(persistentReady?"旁路由已生效 · 重启保留，直到手动恢复":"当前生效但未保存 · 请手动修复以保留到重启后"):"配置失效 · 请手动修复或恢复自动"):"已读取当前网络 · 未启用工具切换";
        UpdateDetails();
    }
    internal async Task CheckStatus(){
        if(busy||polling||!hasBackup)return;
        polling=true;int revision=operationRevision;
        try{
            var r=await Task.Run(()=>runOperation("Inspect",""));
            // Ignore a snapshot started before a manual action, even if that
            // action has already finished. Polling never issues network writes.
            if(IsDisposed||Disposing||busy||revision!=operationRevision)return;
            if(!Program.Flag(r,"Ok"))throw new Exception(Program.Str(r,"Message"));
            Display(Program.Map(r["Data"]));lastPollingError="";
        }catch(Exception ex){
            if(!IsDisposed&&!Disposing&&!busy&&revision==operationRevision&&lastPollingError!=ex.Message){
                lastPollingError=ex.Message;AddLog("状态读取失败，未修改网络："+ex.Message,"ERR");
            }
        }finally{polling=false;}
    }
    internal async Task Execute(string mode){
        if(busy)return;string id=current==null?"":Program.Str(current,"Id");
        operationRevision++;
        busy=true;message=mode=="Inspect"?"正在读取网卡…":"正在切换，请稍候…";UpdateDetails();
        AddLog(mode=="Proxy"?"保存原设置，添加旁路由路由与 DNS…":mode=="Restore"?"正在恢复原网关与 DNS…":mode=="Repair"?"正在按手动请求检查并修复配置…":"读取网卡状态…",mode=="Proxy"?"SAVE":"READ");
        try{
            var r=await Task.Run(()=>runOperation(mode,id));bool ok=Program.Flag(r,"Ok");
            if(!string.IsNullOrEmpty(Program.Str(r,"Message")))AddLog(Program.Str(r,"Message"),!ok?"ERR":mode=="Proxy"?"LINK":mode=="Restore"?"RST":"READ");
            if(r.ContainsKey("Data")&&r["Data"]!=null)Display(Program.Map(r["Data"]));
            else{var snap=await Task.Run(()=>runOperation("Inspect",""));if(Program.Flag(snap,"Ok"))Display(Program.Map(snap["Data"]));}
            if(!ok)message="操作未完成 · 请查看日志";
        }catch(Exception ex){AddLog(ex.Message,"ERR");message="操作未完成 · 请查看日志";}
        finally{busy=false;UpdateDetails();}
    }
    internal void LoadAutoPreview(){
        Display(new Dictionary<string,object>{{"HasBackup",false},{"Active",false},{"Adapters",new object[]{new Dictionary<string,object>{{"Id","00000000-0000-0000-0000-000000000001"},{"Name","Ethernet"},{"Address","192.168.1.148"},{"Dhcp",true},{"Gateway","192.168.1.1"},{"Dns","192.168.1.1"},{"Target","192.168.1.192"},{"IPv6",true}}}}});
        AddLog("已恢复原网关与自动 DNS。","RST");
    }    internal void LoadPreview(){
        Display(new Dictionary<string,object>{{"HasBackup",true},{"Active",true},{"PersistentReady",true},{"BackupAdapter","Ethernet"},{"Adapters",new object[]{
            new Dictionary<string,object>{{"Id","00000000-0000-0000-0000-000000000001"},{"Name","Ethernet"},{"Address","192.168.1.148"},{"Dhcp",true},{"Gateway","192.168.1.1"},{"Dns","192.168.1.192"},{"Target","192.168.1.192"},{"IPv6",true}},
            new Dictionary<string,object>{{"Id","00000000-0000-0000-0000-000000000002"},{"Name","Ethernet 3"},{"Address","10.0.0.2"},{"Dhcp",false},{"Gateway",""},{"Dns",""},{"Target",""},{"IPv6",true}}}}});
        AddLog("读取网卡状态…");AddLog("已读取当前网卡；没有修改网络。");AddLog("保存原网关与 DNS 设置。","SAVE");AddLog("旁路由路由已启用，保留 DHCP 默认网关。","LINK");
    }
}
internal class AdapterSelector : Control {
    internal readonly List<AdapterChoice> Items=new List<AdapterChoice>();
    int selected=-1;
    internal event EventHandler SelectedIndexChanged;
    ToolStripDropDown popup;
    internal int SelectedIndex {
        get{return selected;}
        set{selected=value;Invalidate();if(SelectedIndexChanged!=null)SelectedIndexChanged(this,EventArgs.Empty);}
    }
    internal object SelectedItem {get{return selected>=0&&selected<Items.Count?Items[selected]:null;}}
    public AdapterSelector(){
        SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.Selectable,true);
        Cursor=Cursors.Hand;TabStop=true;Font=Theme.Font(15,true);AccessibleName="网卡选择";AccessibleRole=AccessibleRole.ComboBox;
    }
    protected override void OnPaint(PaintEventArgs e){
        var g=e.Graphics;g.Clear(Theme.Panel);
        using(var p=new Pen(Theme.Cyan,2))g.DrawLine(p,0,Height-1,Width,Height-1);
        TextRenderer.DrawText(g,SelectedItem==null?"请选择网卡":SelectedItem.ToString(),Font,new Rectangle(14,0,Width-60,Height-2),Theme.Text,TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
        g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        int x=Width-25,y=Height/2;
        using(var b=new SolidBrush(Theme.Cyan))g.FillPolygon(b,popup!=null&&popup.Visible?new[]{new Point(x-6,y+3),new Point(x+6,y+3),new Point(x,y-5)}:new[]{new Point(x-6,y-4),new Point(x+6,y-4),new Point(x,y+4)});
        if(Focused){using(var p=new Pen(Theme.Cyan))g.DrawLine(p,14,Height-5,Width-14,Height-5);}
    }
    protected override void OnClick(EventArgs e){base.OnClick(e);Focus();Open();}
    protected override bool IsInputKey(Keys key){return key==Keys.Down||key==Keys.Up||base.IsInputKey(key);}
    protected override void OnKeyDown(KeyEventArgs e){
        base.OnKeyDown(e);
        if(e.KeyCode==Keys.Space||e.KeyCode==Keys.Enter||e.KeyCode==Keys.F4||(e.Alt&&e.KeyCode==Keys.Down)){Open();e.Handled=true;}
        else if(e.KeyCode==Keys.Down&&Items.Count>0){SelectedIndex=Math.Min(Items.Count-1,selected+1);e.Handled=true;}
        else if(e.KeyCode==Keys.Up&&Items.Count>0){SelectedIndex=Math.Max(0,selected-1);e.Handled=true;}
    }
    protected override void OnGotFocus(EventArgs e){base.OnGotFocus(e);Invalidate();}
    protected override void OnLostFocus(EventArgs e){base.OnLostFocus(e);Invalidate();}
    void Open(){
        if(Items.Count==0)return;
        if(popup!=null&&popup.Visible){popup.Close();return;}
        var list=new ListBox{BorderStyle=BorderStyle.None,DrawMode=DrawMode.OwnerDrawFixed,ItemHeight=38,BackColor=Theme.Deep,ForeColor=Theme.Text,Font=Font,Width=Width-2,Height=Math.Min(228,Items.Count*38),IntegralHeight=false};
        foreach(var a in Items)list.Items.Add(a);
        list.SelectedIndex=selected;
        list.DrawItem+=(s,e)=>{
            if(e.Index<0)return;
            bool hi=(e.State&DrawItemState.Selected)!=0;
            using(var b=new SolidBrush(hi?Theme.Cyan:Theme.Deep))e.Graphics.FillRectangle(b,e.Bounds);
            var r=e.Bounds;r.X+=14;r.Width-=28;
            TextRenderer.DrawText(e.Graphics,list.Items[e.Index].ToString(),Font,r,hi?Theme.Bg:Theme.Text,TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
        };
        var host=new ToolStripControlHost(list){Margin=Padding.Empty,Padding=Padding.Empty,AutoSize=false,Size=list.Size};
        popup=new ToolStripDropDown{Padding=new Padding(1),BackColor=Theme.Cyan,AutoClose=true,DropShadowEnabled=true};
        popup.Items.Add(host);
        list.MouseMove+=(s,e)=>{int i=list.IndexFromPoint(e.Location);if(i>=0)list.SelectedIndex=i;};
        list.MouseClick+=(s,e)=>{if(list.SelectedIndex>=0){SelectedIndex=list.SelectedIndex;popup.Close();}};
        list.KeyDown+=(s,e)=>{if(e.KeyCode==Keys.Enter){SelectedIndex=list.SelectedIndex;popup.Close();e.Handled=true;}else if(e.KeyCode==Keys.Escape)popup.Close();};
        popup.Closed+=(s,e)=>{Invalidate();};
        popup.Show(this,new Point(0,Height+4));list.Focus();Invalidate();
    }
}
