"""Offline contract checks against the SAME compiled Swift planner/validator as the app."""
import json, pathlib, subprocess, os
ROOT=pathlib.Path(__file__).resolve().parents[1]
APPS=[{"id":"com.apple.finder","name":"访达"},{"id":"com.google.Chrome","name":"Google Chrome"},{"id":"com.tencent.xinWeChat","name":"微信"}]
def call(payload, validate=False):
    p=subprocess.run([str(ROOT/"local-cache/tools/intent-cli"),"--stream"]+(["--validate"] if validate else []),
        input=json.dumps({"apps":APPS,**payload})+"\n",text=True,capture_output=True,check=True,env={**os.environ,"CMDPALM_AI_CONFIG":os.devnull})
    return json.loads(p.stdout)
valid=[
 {"kind":"text","text":"Hello world，下午三点 review PR。","enter":False},
 {"kind":"app","id":"com.google.Chrome","op":"open"},
 {"kind":"folder","name":"downloads"},{"kind":"volume","value":0.3},
 {"kind":"volume","muted":False},
 {"kind":"url","url":"https://github.com","app":"com.google.Chrome"},
]
invalid=[
 {"kind":"text","text":"你好","enter":True},
 {"kind":"text","text":"你好","enter":0},
 {"kind":"text","text":"你好","enter":"false"},
 {"kind":"app","id":"missing.app","op":"open"},
 {"kind":"app","id":"com.google.Chrome","op":"toggle"},
 {"kind":"shell","command":"echo bad"},
 {"kind":"url","url":"javascript:alert(1)"},
 {"kind":"url","url":"https://github.com","app":"com.tencent.xinWeChat"},
 {"kind":"url","url":"https://github.com","app":123},
 {"kind":"volume","value":True},{"kind":"volume","muted":0},
 {"kind":"volume","value":0.4,"delta":0.1},{"kind":"volume","value":1.1},
 {"kind":"text","text":"hello","unexpected":"ignored?"},
]
for step in valid:
    assert "error" not in call({"plan":{"decision":"execute","steps":[step]}},True), step
for step in invalid:
    assert "error" in call({"plan":{"decision":"execute","steps":[valid[1],step]}},True), step
assert "error" in call({"plan":{"decision":"execute","steps":valid*2}},True)
cases=[
 ("你好","noop",None),
 ("打开微信","execute",None),
 ("帮我打开微信","execute",None),
 ("请帮我把微信调出来","execute",None),
 ("麻烦切到微信","execute",None),
 ("微信启动一下","execute",None),
 ("Everything.","clarify",None),
 ("Please type this exactly: Don't close Chrome. Keep GitHub Actions unchanged.","execute","Don't close Chrome. Keep GitHub Actions unchanged."),
 ("微信输入：Hello world，下午三点 review PR。","execute","Hello world，下午三点 review PR。"),
 ("输入 Don't close Chrome. Copy the API docs!","execute"," Don't close Chrome. Copy the API docs!"),
 ("刚才操作的是哪个应用，我忘了。","noop",None),
]
for text,decision,literal in cases:
    result=call({"text":text,"context":{"recentApp":"com.apple.finder"}})
    assert result["decision"]==decision and result["source"]=="local",(text,result)
    if literal is not None: assert result["steps"][-1]["text"]==literal,(text,result)
    if "微信" in text and literal is None:
        assert result["steps"]==[{"kind":"app","id":"com.tencent.xinWeChat","op":"open"}],(text,result)
for text in ["不要打开微信","别帮我打开微信","先别打开微信，打开访达"]:
    result=call({"text":text})
    assert result["source"]!="local" and result["decision"]!="execute",(text,result)
print("Offline intent contract: "+str(len(valid)+len(invalid)+len(cases)+4)+" checks passed; no API or desktop actions.")
