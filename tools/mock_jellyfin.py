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
def lyrics_for(tid):
    # plain mode: only the first track of an album has lyrics, one line every 2 s
    if not tid.endswith("t1"): return None
    return [(i*20000000,t) for i,t in enumerate(LYRICS)]
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

# ---------------------------------------------------------------------------------
# DEMO=a / DEMO=b: a fictional catalogue split across two servers, with varied cover
# art and lyrics on every track. Used to make the demo video. (Needs numpy.)
# ---------------------------------------------------------------------------------
if os.environ.get("DEMO") in ("a","b"):
    import random
    import numpy as np
    CATALOG=[
     ("Neon Medusa",[("Bioluminescence",2024,"jelly",["Glow Protocol","Tentacle Hymn","Midnight Bloom","Static Tide","Lantern Eyes","Afterglow"]),
                     ("Wireframe Ocean",2022,"grid",["Reboot the Ocean","Pulse Width","Deep Fade","Sync or Sink","Wireframe Heart","Signal Lost"])]),
     ("The Undertow Club",[("Low Tide Radio",2019,"waves",["Sonar Ghosts","Drift","Salt Air","Last Call at the Pier","Kelp Forest","Slack Water"]),
                           ("Salt & Static",2021,"stripes",["Brine","White Noise Tide","Barnacle Boogie","Rip Current","Harbor Lights","Foghorn Lullaby"])]),
     ("Hadal Zone",[("Pressure",2021,"rings",["Midnight Zone","Crush Depth","Lantern Fish","Trench Radio","Black Smoker","Weightless"])]),
     ("Coral Static",[("Reef Signals",2023,"mosaic",["Polyp Parade","Anemone","Bleached","Clownfish Disco","Tidepool","Spawn Night"])]),
     ("Lanternfish",[("After the Last Light",2020,"moon",["Moonpool","Nightshift","Abyssal Plain","Phosphor","Hush","Vantablack"])]),
     ("Kraken Jones",[("Deep Cuts",2018,"sunset",["Release the Kraken","Eight Arms Open","Ink Cloud","Sea Shanty 2.0","Maelstrom","Davy's Locker"])]),
     ("Siren Protocol",[("Echo Location",2025,"grid",["Call and Response","Sonar Love","Frequency","Hydrophone","Lighthouse","Shore Leave"])]),
     ("Tidal Wave Goodbye",[("Ebb",2017,"sunset",["Going Out","Sandcastle","Undertow Letters","Low Water Mark","Driftwood","Last Wave"])]),
    ]
    MINE={"a":[0,1,2,4,6],"b":[3,5,7]}[os.environ["DEMO"]]
    ARTISTS=[]; ALBUMS={}; ALB_ARTIST={}; ALB_INFO={}
    for ai in MINE:
        an,albs=CATALOG[ai]; aid=f"da{ai}"; ARTISTS.append((aid,an)); ALBUMS[aid]=[]
        for bi,(bn,yr,sty,trs) in enumerate(albs):
            bid=f"da{ai}-{bi}"; ALBUMS[aid].append((bid,bn,yr)); ALB_ARTIST[bid]=aid; ALB_INFO[bid]=(bn,sty,trs)
    ARTIST_NAME=dict(ARTISTS)

    def tracks(al):
        bn,sty,trs=ALB_INFO[al]; art=ARTIST_NAME[ALB_ARTIST[al]]
        rnd=random.Random(al)
        return [{"Id":f"{al}t{i+1}","Name":t,"Type":"Audio","Album":bn,"AlbumId":al,"AlbumArtist":art,"Artists":[art],
                 "RunTimeTicks":rnd.randint(172,251)*10**7,"IndexNumber":i+1} for i,t in enumerate(trs)]

    POOL=["Down where the lanterns glow","Every signal finds its shore","Tentacles reaching through the static","We were never meant to surface",
          "Sync your heartbeat to the tide","Neon in the undertow","Hold your breath, hold the line","Pressure builds, the music swells",
          "Float on, float on, float on","Underneath the city lights","The current knows the way home","Bioluminescent dreams",
          "Dive in, don't look back","Salt on my skin, static in my veins","Play it loud till the ocean hears","We glow in the dark together"]
    def lyrics_for(tid):
        rnd=random.Random(tid); lines=POOL[:]; rnd.shuffle(lines)
        return [(int((2+i*4.2)*10**7),t) for i,t in enumerate(lines[:14])]

    def tone():   # a quiet 90 s drone so the player has something to play (the demo mutes it)
        n=22050*90; t=np.arange(n)/22050
        y=0.10*np.sin(2*np.pi*110*t)+0.05*np.sin(2*np.pi*165*t)+0.03*np.sin(2*np.pi*220*t)
        b=io.BytesIO(); w=wave.open(b,"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
        w.writeframes((y*32767).astype("<i2").tobytes()); w.close(); return b.getvalue()
    TONE=tone()

    def lerp(a,b,t): return a+(b-a)*t
    def grad(n,stops,axis=0):
        yy,xx=np.mgrid[0:n,0:n]/(n-1); v=yy if axis==0 else xx
        out=np.zeros((n,n,3))
        for (p0,c0),(p1,c1) in zip(stops,stops[1:]):
            m=(v>=p0)&(v<=p1); t=((v-p0)/(p1-p0+1e-9))[...,None]
            out=np.where(m[...,None],np.array(c0)*(1-t)+np.array(c1)*t,out)
        return out
    def cover(al,n=240):
        sty=ALB_INFO[al][1] if al in ALB_INFO else "rings"
        yy,xx=np.mgrid[0:n,0:n]/(n-1); rnd=np.random.RandomState(abs(hash(al))%2**31)
        if sty=="sunset":
            img=grad(n,[(0,(30,8,80)),(.45,(255,60,140)),(1,(255,180,70))])
            d=np.hypot(xx-.5,yy-.58); sun=d<.24
            sunc=grad(n,[(.34,(255,235,120)),(.82,(255,90,110))])
            img=np.where(sun[...,None],sunc,img)
            stripe=(yy>.60)&(np.sin(yy*90)>.15)&sun; img=np.where(stripe[...,None],np.array((40,10,70)),img)
        elif sty=="grid":
            img=grad(n,[(0,(12,6,40)),(.55,(90,20,120)),(.56,(10,4,30)),(1,(30,8,70))])
            d=np.hypot(xx-.5,yy-.40); img=np.where((d<.2)[...,None],grad(n,[(.2,(255,240,130)),(.6,(255,60,170))]),img)
            gy=(yy-.56).clip(1e-4); persp=(xx-.5)/gy
            lines=(np.abs((persp*.9)%1-.5)<.035)|(np.abs(((1/gy)*.06)%1-.5)<.03)
            img=np.where(((yy>.56)&lines)[...,None],np.array((40,230,255)),img)
        elif sty=="waves":
            img=grad(n,[(0,(8,24,70)),(1,(10,120,140))])
            for k in range(6):
                y0=.25+k*.13; w=np.sin(xx*(7+k)+k)*.035+y0
                img=np.where((yy>w)[...,None],img*.78+np.array((30,150+k*14,170+k*10))*.22,img)
        elif sty=="jelly":
            img=grad(n,[(0,(6,6,28)),(1,(18,6,50))])
            d=np.hypot((xx-.5)*1.0,(yy-.36)*1.25); bell=np.exp(-(d/.2)**2*2)
            img=img+bell[...,None]*np.array((150,90,255))+np.exp(-(d/.34)**2*2)[...,None]*np.array((20,60,140))
            for k in range(7):
                cx=.3+k*.067; tent=np.exp(-((xx-(cx+np.sin(yy*14+k)*.025))/.008)**2)*((yy>.4)&(yy<.92))
                img=img+tent[...,None]*np.array((60,230,255))*(1-yy[...,None]*.6)
        elif sty=="moon":
            img=grad(n,[(0,(5,10,40)),(1,(40,16,80))])
            for _ in range(70):
                sx,sy=rnd.randint(0,n),rnd.randint(0,int(n*.8)); img[sy:sy+2,sx:sx+2]=(255,255,230)
            d=np.hypot(xx-.64,yy-.36); img=np.where((d<.22)[...,None],np.array((236,238,220)),img)
            for cx,cy,r in [(.58,.3,.04),(.7,.42,.05),(.62,.46,.025)]:
                img=np.where((np.hypot(xx-cx,yy-cy)<r)[...,None]&(d<.22)[...,None],np.array((205,208,190)),img)
        elif sty=="stripes":
            v=((xx+yy)*5)%1; img=np.where((v<.33)[...,None],np.array((255,214,10)),np.where((v<.66)[...,None],np.array((20,190,150)),np.array((20,40,90))))
            img=np.where((np.hypot(xx-.5,yy-.5)<.16)[...,None],np.array((250,250,240)),img)
        elif sty=="mosaic":
            pal=[(255,95,120),(255,200,60),(40,200,170),(70,110,255),(160,80,230),(20,30,70)]
            blk=rnd.randint(0,len(pal),(8,8)); img=np.array(pal)[np.kron(blk,np.ones((n//8+1,n//8+1),int))[:n,:n]].astype(float)
        else:  # rings
            r=np.hypot(xx-.5,yy-.5); h=(np.sin(r*38)*.5+.5)
            img=np.stack([30+h*40,90+h*150*(1-r),200+h*55],axis=-1)*(1-r[...,None]*.9)
        a=np.clip(img,0,255).astype(np.uint8)
        raw=b"".join(b"\x00"+a[y].tobytes() for y in range(n))
        def ch(t,d): c=struct.pack(">I",len(d))+t+d; return c+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
        return b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",n,n,8,2,0,0,0))+ch(b"IDAT",zlib.compress(raw))+ch(b"IEND",b"")

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
            lines=lyrics_for(tid)
            if lines is None: return self.send_json(404,{})
            return self.send_json(200,{"Metadata":{},"Lyrics":[{"Start":st,"Text":t} for st,t in lines]})
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
