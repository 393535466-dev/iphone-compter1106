"""Import only explicitly requested API credentials; no histories or pairing tokens."""
import argparse, json, os, pathlib, tempfile
p=argparse.ArgumentParser();p.add_argument("legacy",type=pathlib.Path);args=p.parse_args()
l=json.loads((args.legacy/"llm-config.json").read_text())
a=json.loads((args.legacy/"asr-config.json").read_text()).get("realtime",{})
if not l.get("apiKey") or not a.get("apiKey"):raise SystemExit("Required existing keys are missing; nothing was imported.")
directory=pathlib.Path.home()/"Library/Application Support/CmdPalm AI"
directory.mkdir(parents=True,exist_ok=True);directory.chmod(0o700)
target=directory/"ai-config.json"
if target.exists():raise SystemExit("A configuration already exists; refusing to overwrite it.")
data={"provider":"deepseek","deepseek":{"apiKey":l["apiKey"],"baseURL":l.get("baseUrl","https://api.deepseek.com/v1"),"model":"deepseek-flash"},"qwen":{"apiKey":a["apiKey"],"baseURL":"https://dashscope.aliyuncs.com/compatible-mode/v1","model":"qwen-flash"},"speech":{"provider":"aliyun","apiKey":a["apiKey"],"model":a.get("model","qwen3-asr-flash-realtime"),"workspace":a.get("workspace","")}}
fd,tmp=tempfile.mkstemp(prefix=".ai-config-",dir=directory)
try:
 with os.fdopen(fd,"w") as f:json.dump(data,f,ensure_ascii=False,indent=2)
 os.chmod(tmp,0o600);os.replace(tmp,target)
except BaseException:
 pathlib.Path(tmp).unlink(missing_ok=True);raise
print("Imported the two existing API keys into a private Mac-only configuration. No keys are printed.")
