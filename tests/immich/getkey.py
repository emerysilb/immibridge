"""Admin-signup + API-key bootstrap for a fresh throwaway Immich stack.

    python3 getkey.py http://localhost:2400   ->  prints an API key

v3 requires an explicit `permissions` list on api-keys; v2 rejects the field.
Try the v3 shape first, fall back to the v2 shape.
"""
import json,sys,urllib.request,urllib.error,uuid
BASE=sys.argv[1]
def req(m,p,b=None,tok=None):
    h={"Content-Type":"application/json"}
    if tok: h["Authorization"]="Bearer "+tok
    r=urllib.request.Request(BASE+"/api/"+p,data=json.dumps(b).encode() if b else None,headers=h,method=m)
    try:
        with urllib.request.urlopen(r,timeout=30) as x: return json.loads(x.read())
    except urllib.error.HTTPError as e: return json.loads(e.read() or b'{}')
req("POST","auth/admin-sign-up",{"email":"admin@immibridge.test","password":"test1234","name":"A"})
t=req("POST","auth/login",{"email":"admin@immibridge.test","password":"test1234"})["accessToken"]
for body in ({"name":"h"+uuid.uuid4().hex[:6],"permissions":["all"]},{"name":"h"+uuid.uuid4().hex[:6]}):
    r=req("POST","api-keys",body,tok=t)
    k=r.get("secret") or (r.get("apiKey") or {}).get("secret")
    if k: print(k); break
