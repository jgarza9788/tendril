import os, zlib, json, http.server, io, math, struct, wave, sys, urllib.parse
PORT=int(sys.argv[1]); NAME=sys.argv[2]
ARTISTS=[("ar1","Cnidaria"),("ar2","Hadal"),("ar3","Undertow")]
ALBUMS={"ar1":[("al1","Medusa",2024)],"ar2":[("al2","Pressure",2021),("al3","Trench",2023)],"ar3":[("al4","Low Tide Radio",2019)]}
ALB_ARTIST={a[0]:k for k,v in ALBUMS.items() for a in v}
BIG=os.environ.get("BIG")=="1"          # 702 artists, paged like a real library
REVOKE=os.environ.get("REVOKE_FILE")     # if this file exists, every request gets 401
SERVER_ERR=os.environ.get("ERR_ALBUM")   # audio for this album answers 500
BAD_FILE=os.environ.get("BAD_ALBUM")     # audio for this album is 200 but not audio
if BIG:
    ARTISTS=[(f"big{i}",f"{chr(65+i//27)} Artist {i%27:02d}") for i in range(702)]
    for aid,_ in ARTISTS: ALBUMS.setdefault(aid,[(aid+"-al",f"Album of {aid}",2000)]); ALB_ARTIST[aid+"-al"]=aid
ARTIST_NAME=dict(ARTISTS)
LOG=os.environ.get("LOG_FILE")          # append one line per report / favourite / playlist request
FAVS=set()
def log(*a):
    if LOG: open(LOG,"a").write(" ".join(str(x) for x in a)+"\n")
LYRICS=["Down in the deep","where the lanterns glow","the tentacles reach out","through the undertow","and the current knows","the way back home"]
def tracks(al):
    return [{"Id":f"{al}t{i}","Name":f"{NAME} Track {i}","Type":"Audio","Album":al,"AlbumId":al,"AlbumArtist":ARTIST_NAME[ALB_ARTIST[al]],"Artists":[ARTIST_NAME[ALB_ARTIST[al]]],"RunTimeTicks":8*10**7*8,"IndexNumber":i} for i in range(1,5)]
def tone():
    b=io.BytesIO(); w=wave.open(b,"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
    w.writeframes(b"".join(struct.pack("<h",int(6000*math.sin(2*math.pi*330*i/22050))) for i in range(22050*8))); w.close(); return b.getvalue()
TONE=tone()
HUES={"al1":(230,60,60),"al2":(40,140,255),"al3":(60,220,120),"al4":(255,170,30)}
def cover(al,n=160):
    r,g,b=HUES.get(al,(200,200,200)); rows=[]
    for y in range(n):
        row=bytearray([0])
        for x in range(n):
            d=math.hypot(x-n/2,y-n/2)/(n/2); k=max(0.0,1-d)
            ring=0.5+0.5*math.sin(d*12)
            row+=bytes([int(r*k*ring*0.8+20),int(g*k*ring*0.8+20),int(b*k*ring*0.8+30)])
        rows.append(bytes(row))
    raw=zlib.compress(b"".join(rows))
    def ch(t,d): c=struct.pack(">I",len(d))+t+d; return c+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
    return b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",n,n,8,2,0,0,0))+ch(b"IDAT",raw)+ch(b"IEND",b"")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send_json(self,code,obj):
        b=json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def authed(self):
        return "tok-"+NAME in self.headers.get("Authorization","") and not (REVOKE and os.path.exists(REVOKE))
    def read_body(self):
        n=int(self.headers.get("Content-Length",0)); raw=self.rfile.read(n) if n else b""
        try: return json.loads(raw) if raw else {}
        except Exception: return {}
    def do_POST(self):
        body=self.read_body(); path=urllib.parse.urlparse(self.path).path
        if path=="/Users/AuthenticateByName":
            if body.get("Pw")=="pw": return self.send_json(200,{"AccessToken":"tok-"+NAME,"ServerId":NAME,"User":{"Id":"u-"+NAME,"Name":body["Username"]}})
            return self.send_json(401,{})
        if not self.authed(): return self.send_json(401,{})
        if path.startswith("/Sessions/Playing"):
            log("report",path,body.get("ItemId"),body.get("PositionTicks"),body.get("IsPaused")); self.send_response(204); self.end_headers(); return
        if path=="/Playlists":
            log("playlist",body.get("Name"),",".join(body.get("Ids",[]))); return self.send_json(200,{"Id":"pl-new"})
        if "/FavoriteItems/" in path:
            iid=path.rsplit("/",1)[1]; FAVS.add(iid); log("favorite",iid,"on"); return self.send_json(200,{"IsFavorite":True})
        self.send_json(404,{})
    def do_DELETE(self):
        path=urllib.parse.urlparse(self.path).path
        if not self.authed(): return self.send_json(401,{})
        if "/FavoriteItems/" in path:
            iid=path.rsplit("/",1)[1]; FAVS.discard(iid); log("favorite",iid,"off"); return self.send_json(200,{"IsFavorite":False})
        self.send_json(404,{})
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(u.query)
        if REVOKE and os.path.exists(REVOKE): return self.send_json(401,{})
        if u.path.startswith("/Audio/") and u.path.endswith("/Lyrics"):
            if not self.authed(): return self.send_json(401,{})
            tid=u.path.split("/")[2]
            if not tid.endswith("t1"): return self.send_json(404,{})
            return self.send_json(200,{"Metadata":{},"Lyrics":[{"Start":i*20000000,"Text":t} for i,t in enumerate(LYRICS)]})
        if u.path.startswith("/Audio/"):
            alb=u.path.split("/")[2].split("t")[0]
            if alb==SERVER_ERR: return self.send_json(500,{})
            if alb==BAD_FILE:
                junk=b"this is not audio"*100; self.send_response(200); self.send_header("Content-Type","audio/mpeg"); self.send_header("Content-Length",str(len(junk))); self.end_headers(); self.wfile.write(junk); return
            # real servers take the token as a header (newer ones reject the api_key query param)
            if not (self.authed() or q.get("ApiKey",[""])[0]=="tok-"+NAME): return self.send_json(401,{})
            self.send_response(200); self.send_header("Content-Type","audio/wav"); self.send_header("Content-Length",str(len(TONE))); self.end_headers(); self.wfile.write(TONE); return
        if "tok-"+NAME not in self.headers.get("Authorization",""): return self.send_json(401,{})
        if u.path.startswith("/Items/") and "/Images/" in u.path:
            png=cover(u.path.split("/")[2]); self.send_response(200); self.send_header("Content-Type","image/png"); self.send_header("Content-Length",str(len(png))); self.end_headers(); self.wfile.write(png); return
        items=[]
        total=None
        if u.path=="/Artists/AlbumArtists":
            allitems=[{"Id":i,"Name":f"{n}","Type":"MusicArtist"} for i,n in ARTISTS]
            term=q.get("SearchTerm",[""])[0].lower()
            if term: allitems=[x for x in allitems if term in x["Name"].lower()]
            frm=q.get("NameStartsWithOrGreater",[""])[0].upper()
            if frm: allitems=[x for x in allitems if x["Name"].upper()>=frm]
            st=int(q.get("StartIndex",["0"])[0]); lim=int(q.get("Limit",["200"])[0])
            total=len(allitems); items=allitems[st:st+lim]
        elif u.path=="/Items":
            t=q.get("IncludeItemTypes",[""])[0]
            if "IsFavorite" in q.get("Filters",[""])[0]:
                pool=[{"Id":i,"Name":n,"Type":"MusicArtist"} for i,n in ARTISTS]
                pool+=[{"Id":a,"Name":n,"Type":"MusicAlbum","AlbumArtist":ARTIST_NAME[k],"ProductionYear":y} for k in ALBUMS for a,n,y in ALBUMS[k]]
                pool+=[x for al in ALB_ARTIST for x in tracks(al)]
                items=[x for x in pool if x["Id"] in FAVS]; total=len(items)
            elif t=="MusicAlbum":
                ids=[q["AlbumArtistIds"][0]] if "AlbumArtistIds" in q else list(ALBUMS)
                items=[{"Id":a,"Name":n,"Type":"MusicAlbum","AlbumArtist":ARTIST_NAME[k],"ProductionYear":y} for k in ids for a,n,y in ALBUMS[k]]
                term=q.get("SearchTerm",[""])[0].lower()
                if term: items=[x for x in items if term in x["Name"].lower()]
            elif t=="Audio" and "ParentId" in q: items=tracks(q["ParentId"][0])
            elif t=="Audio" and "SearchTerm" in q: items=[x for al in ALB_ARTIST for x in tracks(al) if q["SearchTerm"][0].lower() in x["Name"].lower()][:6]
            elif t=="Playlist":
                items=[{"Id":"pl1","Name":f"{NAME} Favourites","Type":"Playlist","ChildCount":4}]
                term=q.get("SearchTerm",[""])[0].lower()
                if term: items=[x for x in items if term in x["Name"].lower()]
        elif u.path.startswith("/Playlists/"): items=tracks("al1")
        for x in items: x["UserData"]={"IsFavorite":x.get("Id") in FAVS}
        self.send_json(200,{"Items":items,"TotalRecordCount":total if total is not None else len(items),"StartIndex":int(q.get("StartIndex",["0"])[0])})
http.server.ThreadingHTTPServer(("127.0.0.1",PORT),H).serve_forever()
