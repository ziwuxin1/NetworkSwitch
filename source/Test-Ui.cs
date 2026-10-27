using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

// Compile with NetworkSwitch.cs, select this entry point, and inject a fake worker.
// No test calls Program.Run or any real network command.
internal static class UiRegression {
    static int passed;
    static void Check(bool condition,string label) {
        if(!condition)throw new Exception("FAIL: "+label);
        passed++;Console.WriteLine("PASS: "+label);
    }
    static object Field(MainForm form,string name) {
        return typeof(MainForm).GetField(name,BindingFlags.Instance|BindingFlags.NonPublic).GetValue(form);
    }
    static void PumpUntil(Func<bool> done) {
        var limit=DateTime.UtcNow.AddSeconds(10);
        while(!done()) {
            if(DateTime.UtcNow>limit)throw new Exception("Test timed out");
            Application.DoEvents();Thread.Sleep(1);
        }
    }
    static void Finish(Task task) { PumpUntil(()=>task.IsCompleted);task.GetAwaiter().GetResult(); }
    static Dictionary<string,object> Result(bool backup,bool active) {
        return new Dictionary<string,object>{{"Ok",true},{"Message",""},{"Data",
            new Dictionary<string,object>{{"HasBackup",backup},{"Active",active},{"PersistentReady",backup},{"RestorePending",false},
                {"Adapters",new object[0]}}}};
    }
    [STAThread] static int Main() {
        try {
            Program.Preview=true;
            Application.EnableVisualStyles();
            var calls=new List<string>();
            using(var form=new MainForm((mode,id)=>{lock(calls)calls.Add(mode);return Result(true,true);})) {
                form.LoadPreview();
                var timer=(System.Windows.Forms.Timer)Field(form,"maintenance");
                Check(timer.Interval==15000,"Periodic interval is 15 seconds");
                // Invoke the actual registered Tick handler through 24 cycles.
                var tick=typeof(System.Windows.Forms.Timer).GetMethod("OnTick",BindingFlags.Instance|BindingFlags.NonPublic);
                for(int n=0;n<24;n++) {
                    tick.Invoke(timer,new object[]{EventArgs.Empty});
                    PumpUntil(()=>!(bool)Field(form,"polling"));
                }
                Check(calls.Count==24&&calls.TrueForAll(mode=>mode=="Inspect"),"24 timer ticks issue only read-only Inspect");
                Check(!((string)Field(form,"message")).Contains("正在切换"),"Polling does not display switching status");
                Check(((string)Field(form,"message")).Contains("重启保留"),"Saved state explicitly shows persistence after reboot");
                Check(((Button)Field(form,"refresh")).Text=="手动修复","Repair is an explicit labeled action");
                Finish(form.Execute("Repair"));
                Check(calls[calls.Count-1]=="Repair","Manual repair invokes worker only on request");
            }
            using(var gate=new ManualResetEventSlim(false))
            using(var started=new ManualResetEventSlim(false))
            using(var form=new MainForm((mode,id)=>{
                if(mode=="Inspect"){started.Set();gate.Wait();return Result(true,true);}
                if(mode=="Restore")return Result(false,false);
                throw new Exception("Unexpected mutation "+mode);
            })) {
                form.LoadPreview();
                var poll=form.CheckStatus();PumpUntil(()=>started.IsSet);
                Check(((Button)Field(form,"restore")).Enabled,"Background polling leaves restore available");
                var duplicate=form.CheckStatus();
                Check(duplicate.IsCompleted,"Overlapping timer tick is skipped");
                Finish(form.Execute("Restore"));
                gate.Set();Finish(poll);
                Check(!(bool)Field(form,"hasBackup")&&!(bool)Field(form,"isActive"),"Stale poll cannot overwrite completed restore");
            }
            using(var form=new MainForm((mode,id)=>{
                var result=Result(true,true);
                var data=(Dictionary<string,object>)result["Data"];
                data["LegacyState"]=true;data["PersistentReady"]=false;return result;
            })) {
                form.LoadPreview();Finish(form.CheckStatus());
                Check(((string)Field(form,"message")).Contains("旧版临时配置"),"Old snapshot is clearly identified as temporary");
                Check(((Button)Field(form,"refresh")).Text.Contains("刷新"),"Legacy state does not offer silent persistent repair");
            }
            using(var form=new MainForm((mode,id)=>{
                var result=Result(true,true);
                ((Dictionary<string,object>)result["Data"])["PersistentReady"]=false;return result;
            })) {
                form.LoadPreview();Finish(form.CheckStatus());
                Check(((string)Field(form,"message")).Contains("当前生效但未保存"),"Active-only state is not falsely shown as reboot-ready");
            }
            calls.Clear();
            using(var form=new MainForm((mode,id)=>{
                calls.Add(mode);
                if(mode!="Inspect")throw new Exception("Unexpected mutation "+mode);
                return new Dictionary<string,object>{{"Ok",false},{"Message","Simulated read failure"},{"Data",null}};
            })) {
                form.LoadPreview();int before=(int)Field(form,"logCount");
                for(int n=0;n<4;n++)Finish(form.CheckStatus());
                Check(calls.Count==4&&calls.TrueForAll(mode=>mode=="Inspect"),"Polling errors never trigger repair or rollback");
                Check((bool)Field(form,"hasBackup"),"Polling errors retain existing mode");
                Check((int)Field(form,"logCount")==before+1,"Repeated polling error is logged once");
            }
            Console.WriteLine("TOTAL: "+passed+" UI checks passed");return 0;
        }catch(Exception ex){Console.Error.WriteLine(ex);return 1;}
    }
}
