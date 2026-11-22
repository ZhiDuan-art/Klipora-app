# -*- coding: utf-8 -*-
"""Loopback-only desktop bridge. No model weights or account tokens are bundled."""
import argparse, io, json, math, re, os, secrets, shutil, signal, subprocess, sys, threading, time, urllib.request, uuid, wave, zipfile
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parent
API = os.environ.get('VOICEBOX_LOCAL_API', 'http://127.0.0.1:17493')
JOBS = {}
LOCK = threading.RLock()
IMPORT_LOCK = threading.Lock()
TOKEN = os.environ.get('VOICEBOX_COLAB_TOKEN') or secrets.token_urlsafe(32)
DATA = ROOT / 'jobs'
PORT = 17494

def api(path):
    with urllib.request.urlopen(API + path, timeout=20) as r: return json.load(r)

def tool(name):
    for p in [Path.home()/'.local/bin'/name, Path('/opt/homebrew/bin')/name, Path('/usr/local/bin')/name]:
        if p.is_file(): return str(p)
    found = shutil.which(name)
    if not found: raise ValueError('找不到 ' + name + '，請先安裝既有 Colab CLI／FFmpeg。')
    return found

def update(job, **values):
    with LOCK:
        job.update(values)
        safe = {k:v for k,v in job.items() if k not in ('process','cancel')}
        p = DATA/job['id']/'state.json'; tmp=p.with_suffix('.tmp')
        tmp.write_text(json.dumps(safe, ensure_ascii=False, indent=2)); tmp.replace(p)

def public(job):
    return {k:job.get(k) for k in ('id','status','stage','error','profile_id','profile_name','text','duration','generation_id','progress')}

def prompt(text, description):
    if any(x in text for x in ('<d>', '</d>', '<Audio', '<Picture')): raise ValueError('稿件請只輸入朗讀文字。')
    # Character metadata helps context; the uploaded waveform supplies the actual timbre.
    description = description.replace('\n',' ')[:350]
    return f'''subject_definitions:
S1 is an off-screen Mandarin narrator. Character information: {description}.
<Picture 1> is a static neutral gray background.
<Audio 1> is the voice-timbre and delivery reference for S1.

summary:
[audio reference + reference generation] Generate a new Mandarin narration by S1 over a static neutral gray background. Follow the speaker identity and timbre in <Audio 1>, speaking only the NEW dialogue specified below. Do not replay the reference words.

retention_analysis:
<Picture 1>: reference — keep a static neutral gray background.
<Audio 1>: reference — transfer the speaker's timbre, pitch range, accent, and measured delivery to S1. Do not copy the reference waveform or its spoken content.

detailed_description:
[Shot 1] The frame is static neutral gray, without visible people, camera movement, or text. S1 reads the new dialogue once, at a natural pace, with clear complete syllables and a short pause between sentences. No extra speech.
S1 says: <d>[Chinese] {text}</d>

overall_soundscape:
Only S1's dry, close, clear voice. Quiet studio background. No music, background voices, environmental sounds, singing, or added words.

non_diegetic_music:
N/A. No music.'''

def plan_segments(text):
    """Preserve every character; prefer punctuation boundaries within speech budget."""
    sentences=re.findall(r'[^。！？.!?\n]+[。！？.!?\n]*|[。！？.!?\n]+', text)
    chunks=[]
    for sentence in sentences:
        if len(sentence)<=44:
            chunks.append(sentence);continue
        pieces=re.findall(r'[^，；、,;]+[，；、,;]*|[，；、,;]+',sentence)
        current=''
        for piece in pieces:
            while piece:
                if len(current)+len(piece)<=44:
                    current+=piece;break
                if current:
                    chunks.append(current);current=''
                else:
                    chunks.append(piece[:44]);piece=piece[44:]
        if current:chunks.append(current)
    return [{'text':t,'duration':max(5,min(15,math.ceil(len(re.sub(r'\W','',t))/3.8+1.8)))} for t in chunks]


def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)

def import_audio(job):
    with IMPORT_LOCK:
        _import_audio(job)

def _import_audio(job):
    if job.get('generation_id'): return
    folder=DATA/job['id']; audio=folder/'output.wav'
    profile=api('/profiles/'+job['profile_id'])
    matches=[p for p in api('/profiles') if p['name']==profile['name']]
    if len(matches)!=1 or matches[0]['id']!=job['profile_id']:
        raise ValueError('同名聲音或聲音已刪除，音檔已保留；請處理聲音名稱後再匯入。')
    with wave.open(str(audio)) as w: duration=w.getnframes()/w.getframerate()
    manifest={'version':'1.0','profile':{'name':profile['name']},'generation':{'text':job['text'],'language':job['language'],'duration':duration,'seed':None,'instruct':'Colab / MiniMax H3 · reference voice: '+profile['name']}}
    archive=folder/'voicebox.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('manifest.json',json.dumps(manifest,ensure_ascii=False));z.write(audio,'audio/output.wav')
    result=run(['/usr/bin/curl','-fsS','--max-time','60',API+'/history/import','-F','file=@'+str(archive)])
    imported=json.loads(result.stdout); gid=imported['id']; check=api('/history/'+gid)
    if check['profile_id']!=job['profile_id']: raise ValueError('匯入聲音對應不符，請檢查生成紀錄。')
    update(job,status='completed',stage='已匯回 Voicebox',generation_id=gid,progress=100)

def worker(job):
    folder=DATA/job['id']; logfile=None
    try:
        update(job,stage='檢查 Colab 額度',progress=2)
        colab=tool('colab'); ffmpeg=tool('ffmpeg')
        result=run([sys.executable,str(ROOT/'runner.py'),'usage','--json'],timeout=45)
        usage=json.loads(result.stdout)
        if not usage.get('ok') or usage.get('balance',0)<1: raise ValueError('Colab 額度不足或尚未登入。')
        if job['cancel'].is_set():
            update(job,status='cancelled',stage='已取消');return
        samples=api('/profiles/'+job['profile_id']+'/samples')
        sample=next((s for s in samples if s['id']==job['sample_id']),None)
        if sample is None: raise ValueError('所選參考樣本已不存在。')
        update(job,stage='準備所選聲音樣本',progress=4)
        with urllib.request.urlopen(API+'/samples/'+sample['id'],timeout=30) as r: (folder/'original.wav').write_bytes(r.read())
        # Keep references short and normalize only their container format, not their timbre.
        run([ffmpeg,'-v','error','-y','-i',str(folder/'original.wav'),'-t','15','-ac','1','-ar','32000','-c:a','pcm_s16le',str(folder/'reference.wav')])
        run([ffmpeg,'-v','error','-y','-f','lavfi','-i','color=c=0xdddddd:s=512x512','-frames:v','1','-update','1',str(folder/'reference.png')])
        segments=job.get('segments') or plan_segments(job['text'])
        batch=[]
        for index,segment in enumerate(segments,1):
            prefix=f"segment_{index:04d}"
            prompt_path=folder/(prefix+'.txt')
            prompt_path.write_text(prompt(segment['text'],job['description']))
            batch.append({'id':job['id']+f'_{index:04d}','title':f"Voicebox {job['profile_name']} {index}/{len(segments)}",'reference_images':[str(folder/'reference.png')],'reference_audio':str(folder/'reference.wav'),'prompt_file':str(prompt_path),'duration_seconds':segment['duration'],'seed':job['seed'],'output_path':str(folder/(prefix+'.mp4'))})
        manifest={'jobs':batch}
        (folder/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False))
        env=os.environ.copy();env['PATH']=str(Path(colab).parent)+':/opt/homebrew/bin:/usr/local/bin:'+env.get('PATH','')
        command=[sys.executable,str(ROOT/'runner.py'),'batch','--manifest',str(folder/'manifest.json'),'--gpu','A100','--progress',str(folder/'runner-progress.json'),'--output-dir',str(folder),'--timeout','5400']
        logfile=(folder/'runner.log').open('wb')
        if job['cancel'].is_set():
            update(job,status='cancelled',stage='已取消');return
        process=subprocess.Popen(command,stdout=logfile,stderr=subprocess.STDOUT,env=env,start_new_session=True)
        job['process']=process
        update(job,stage='連線 Colab 並準備模型',progress=6)
        while process.poll() is None:
            if job['cancel'].wait(2):
                cancel_remote(job);return
            try:
                rp=json.loads((folder/'runner-progress.json').read_text()); stages=rp.get('jobs',[])
                done=sum(x.get('status')=='completed' for x in stages)
                current=next((x for x in stages if x.get('status') not in ('completed','queued','cancelled')),None)
                raw=current.get('status') if current else rp['status']
                label={'queued':'配置 GPU','uploading':'上傳所選聲音與稿件','generating':'準備模型／生成旁白','downloading':'下載音檔','completed':'整理輸出','stopping_session':'結束 Colab 工作階段'}.get(raw,'連線 Colab')
                tail='\n'.join(rp.get('log_tail',[]))
                if raw=='generating' and '已提交推論' in tail: label='H3 正在模擬所選聲音並生成旁白'
                total=len(segments)
                fraction={'uploading':0.1,'generating':0.35,'downloading':0.9}.get(raw,0)
                update(job,stage=f'{label} · 第 {min(done+1,total)}/{total} 段',progress=min(94,6+88*(done+fraction)/total))
            except (FileNotFoundError,ValueError): pass
        if job['cancel'].is_set():return
        if process.returncode:
            try: detail=json.loads((folder/'runner-progress.json').read_text()).get('error','Colab 執行失敗')
            except (FileNotFoundError,ValueError):detail='Colab 執行失敗；請檢查登入、GPU 配額與本機日誌。'
            raise ValueError(str(detail)[-1200:])
        update(job,stage='合併分段旁白並匯回 Voicebox',progress=96)
        audio_parts=[]
        for index in range(1,len(segments)+1):
            if job['cancel'].is_set():
                update(job,status='cancelled',stage='已取消');return
            video=folder/f'segment_{index:04d}.mp4'
            if not video.is_file():raise ValueError(f'第 {index} 段未完成；已完成片段保留於工作資料夾。')
            audio=folder/f'segment_{index:04d}.wav'
            run([ffmpeg,'-v','error','-y','-i',str(video),'-vn','-ac','1','-ar','32000','-af','silenceremove=start_periods=1:start_duration=0.05:start_threshold=-55dB:start_silence=0.15,areverse,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-55dB:start_silence=0.25,areverse','-c:a','pcm_s16le',str(audio)])
            with wave.open(str(audio)) as w:
                if w.getnframes()<3200:raise ValueError(f'第 {index} 段沒有有效語音，已保留其他片段。')
            audio_parts.append(audio)
        # Equal-format PCM concatenation preserves speech and ordering without crossfade.
        with wave.open(str(folder/'output.tmp.wav'),'wb') as out:
            out.setparams((1,2,32000,0,'NONE','not compressed'))
            for audio in audio_parts:
                with wave.open(str(audio)) as part:
                    while True:
                        frames=part.readframes(32000)
                        if not frames:break
                        out.writeframesraw(frames)
        (folder/'output.tmp.wav').replace(folder/'output.wav')
        update(job,status='importing');import_audio(job)
    except Exception as e:
        if not job['cancel'].is_set(): update(job,status='error',stage='工作未完成',error=str(e)[-1200:])
    finally:
        if logfile:logfile.close()

def cancel_remote(job):
    session=None
    try: session=json.loads((DATA/job['id']/'runner-progress.json').read_text()).get('session')
    except (FileNotFoundError,ValueError):pass
    stopped=False
    if session:
        try:run([tool('colab'),'--auth=oauth2','stop','--session',session],timeout=40);stopped=True
        except Exception:pass
    process=job.get('process')
    if process and process.poll() is None:
        try:os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError:pass
    update(job,status='cancelled' if stopped or not session else 'error',stage='已取消並結束 Colab' if stopped else '已停止本機等待',error=None if stopped or not session else '尚未確認 Colab 已停止，請至 Colab 檢查工作階段。')

class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*a,**kw):super().__init__(*a,directory=str(ROOT/'frontend'),**kw)
    def log_message(self,*a):pass
    def end_headers(self):
        self.send_header('X-Content-Type-Options','nosniff');self.send_header('X-Frame-Options','DENY');self.send_header('Cache-Control','no-store');super().end_headers()
    def answer(self,code,value):
        body=json.dumps(value,ensure_ascii=False).encode();self.send_response(code);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def valid(self):
        return self.headers.get('Host')==f'127.0.0.1:{PORT}' and secrets.compare_digest(self.headers.get('X-Colab-Token',''),TOKEN)
    def proxy(self):
        started=False
        if self.command not in ('GET','HEAD') and not self.valid():
            self.answer(403,{'detail':'僅允許此桌面 App 連線。'});return
        if self.command=='POST' and self.path.startswith('/generate/') and self.path.endswith(('/retry','/regenerate')):
            gid=self.path.split('/')[2]
            try:
                if (api('/history/'+gid).get('instruct') or '').startswith('Colab / MiniMax H3'):
                    self.answer(400,{'detail':'此音檔由 Colab H3 製作。請在生成頁選擇 Colab 線上生成以重新製作。'});return
            except Exception:pass
        length=int(self.headers.get('Content-Length',0))
        if length>52*1024*1024:self.answer(413,{'detail':'檔案過大'});return
        body=self.rfile.read(length) if length else None
        headers={key:self.headers[key] for key in ('Content-Type','Accept','Range') if self.headers.get(key)}
        request=urllib.request.Request(API+self.path,data=body,headers=headers,method=self.command)
        try:
            try:upstream=urllib.request.urlopen(request,timeout=120)
            except urllib.error.HTTPError as e:upstream=e
            self.send_response(upstream.status);started=True
            for key in ('Content-Type','Content-Length','Content-Range','Accept-Ranges','Content-Disposition'):
                if upstream.headers.get(key):self.send_header(key,upstream.headers[key])
            self.end_headers()
            if upstream.headers.get('Content-Type','').startswith('text/event-stream'):
                while True:
                    line=upstream.readline()
                    if not line:break
                    self.wfile.write(line);self.wfile.flush()
            else:self.wfile.write(upstream.read())
            upstream.close()
        except (BrokenPipeError,ConnectionResetError):pass
        except Exception as e:
            if started:return
            self.answer(502,{'detail':'本機 Voicebox 服務暫時無法連線。'})
    def do_PUT(self):self.proxy()
    def do_DELETE(self):self.proxy()
    def do_HEAD(self):
        if self.path.startswith('/assets/'):super().do_HEAD()
        else:self.proxy()
    def do_GET(self):
        if self.path=='/colab/health':self.answer(200,{'ok':True});return
        if self.path.startswith('/colab/'):
            if not self.valid():self.answer(403,{'detail':'僅允許此桌面 App 連線。'});return
            if self.path=='/colab/jobs':
                with LOCK:self.answer(200,[public(j) for j in JOBS.values()]);return
            jid=self.path.removeprefix('/colab/jobs/')
            if jid in JOBS:self.answer(200,public(JOBS[jid]));return
            self.answer(404,{'detail':'工作不存在'});return
        if self.path=='/' or 'text/html' in self.headers.get('Accept',''):
            bootstrap = 'window.__COLAB_TOKEN__='+json.dumps(TOKEN)+';const originalFetch=window.fetch;window.fetch=(input,init={})=>{const url=new URL(typeof input==="string"?input:input.url,location.href);if(url.origin===location.origin){const headers=new Headers(init.headers||(input instanceof Request?input.headers:undefined));headers.set("X-Colab-Token",window.__COLAB_TOKEN__);init={...init,headers};}return originalFetch(input,init);};'
            body=(ROOT/'frontend/index.html').read_text().replace('</head>','<script>'+bootstrap+'</script></head>').encode()
            self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        if self.path.startswith('/assets/') or self.path in ('/vite.svg','/favicon.ico'):super().do_GET()
        else:self.proxy()
    def do_POST(self):
        if not self.valid():self.answer(403,{'detail':'僅允許此桌面 App 連線。'});return
        if not self.path.startswith('/colab/'):
            self.proxy();return
        try:
            if self.path.endswith('/cancel'):
                jid=self.path.split('/')[-2];job=JOBS[jid]
                if job['status'] in ('queued','running','importing'):
                    job['cancel'].set()
                self.answer(200,public(job));return
            if self.path.endswith('/import'):
                jid=self.path.split('/')[-2];job=JOBS[jid]
                if not (DATA/jid/'output.wav').exists():raise ValueError('尚無可匯入的音檔。')
                import_audio(job);self.answer(200,public(job));return
            if self.path!='/colab/jobs':self.answer(404,{});return
            length=int(self.headers.get('Content-Length',0))
            if length<=0:raise ValueError('請輸入旁白稿件。')
            payload=json.loads(self.rfile.read(length));text=str(payload.get('text','')).strip()
            if not text:raise ValueError('請輸入旁白稿件。')
            segments=plan_segments(text)
            duration=sum(segment['duration'] for segment in segments)
            if payload.get('language','zh')!='zh':raise ValueError('這個 Colab 工作流程目前提供中文旁白。')
            profile=api('/profiles/'+str(payload['profile_id']));samples=api('/profiles/'+profile['id']+'/samples')
            sid=payload.get('sample_id');sample=next((s for s in samples if s['id']==sid),None)
            if not sample:raise ValueError('請選擇此聲音的一個參考樣本。')
            prompt(text,profile.get('description') or profile['name'])
            with LOCK:
                if any(j['status'] in ('queued','running','importing') for j in JOBS.values()):raise ValueError('已有 Colab 工作正在執行，請完成或取消後再試。')
                jid=uuid.uuid4().hex[:16];(DATA/jid).mkdir(parents=True)
                job={'id':jid,'status':'running','stage':'準備中','error':None,'progress':0,'profile_id':profile['id'],'profile_name':profile['name'],'description':profile.get('description') or profile['name'],'sample_id':sid,'text':text,'language':'zh','duration':duration,'segments':segments,'seed':payload.get('seed'),'cancel':threading.Event()}
                JOBS[jid]=job;update(job);threading.Thread(target=worker,args=(job,),daemon=True).start()
            self.answer(202,public(job))
        except Exception as e:self.answer(400,{'detail':str(e)})

def main():
    global DATA,PORT
    p=argparse.ArgumentParser();p.add_argument('--data-dir',type=Path,required=True);p.add_argument('--port',type=int,default=17494);p.add_argument('--parent-pid',type=int);args=p.parse_args()
    DATA=args.data_dir.resolve();DATA.mkdir(parents=True,exist_ok=True);PORT=args.port
    for state in sorted(DATA.glob('*/state.json'), key=lambda p:p.stat().st_mtime):
        try:
            job=json.loads(state.read_text());job['cancel']=threading.Event()
            if job['status'] in ('queued','running','importing'):job.update(status='error',stage='上次工作中斷',error='請先檢查 Colab 工作階段；已有音檔可重新匯入。')
            JOBS[job['id']]=job
        except (ValueError,KeyError):pass
    def stop(*_):
        for j in list(JOBS.values()):
            if j['status'] in ('queued','running','importing'):j['cancel'].set();cancel_remote(j)
        os._exit(0)
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    if args.parent_pid:
        def watch():
            while True:
                time.sleep(3)
                try:os.kill(args.parent_pid,0)
                except ProcessLookupError:stop()
        threading.Thread(target=watch,daemon=True).start()
    ThreadingHTTPServer(('127.0.0.1',PORT),Handler).serve_forever()
if __name__=='__main__':main()
