{-# LANGUAGE JavaScriptFFI, InterruptibleFFI #-}
-- Browser API bindings only. All application decisions are Haskell in Main.
module Browser where

import GHC.JS.Prim
import GHC.JS.Foreign.Callback
import Data.Text (Text)
import qualified Data.Text as T

js :: Text -> JSVal
js = toJSString . T.unpack
text :: JSVal -> Text
text = T.pack . fromJSString

foreign import javascript unsafe "((id,value) => { document.getElementById(id).textContent=value; })"
  setText :: JSVal -> JSVal -> IO ()
foreign import javascript unsafe "((id) => document.getElementById(id).value)"
  getValue :: JSVal -> IO JSVal
foreign import javascript unsafe "((id,value) => { document.getElementById(id).value=value; })"
  setValue :: JSVal -> JSVal -> IO ()
foreign import javascript unsafe "((id,key,value) => { document.getElementById(id)[key]=value; })"
  setBool :: JSVal -> JSVal -> Bool -> IO ()
foreign import javascript unsafe "((id,url) => { const el=document.getElementById(id); if(url)el.setAttribute('href',url);else el.removeAttribute('href'); el.hidden=!url; })"
  setLink :: JSVal -> JSVal -> IO ()
foreign import javascript unsafe "((id,event,callback) => { document.getElementById(id).addEventListener(event,e=>{if(event==='submit')e.preventDefault();callback();}); })"
  listen :: JSVal -> JSVal -> Callback (IO ()) -> IO ()
foreign import javascript unsafe "((key) => { try{return localStorage.getItem(key)||'';}catch(_){return '';} })"
  readStorage :: JSVal -> IO JSVal
foreign import javascript unsafe "((key,value) => { try{if(value)localStorage.setItem(key,value);else localStorage.removeItem(key);return true;}catch(_){return false;} })"
  writeStorage :: JSVal -> JSVal -> IO Bool
foreign import javascript unsafe "(() => Array.from(crypto.getRandomValues(new Uint8Array(32)),n=>n.toString(16).padStart(2,'0')).join(''))"
  randomHex :: IO JSVal
foreign import javascript unsafe "((value) => encodeURIComponent(value))"
  urlEncode :: JSVal -> IO JSVal
foreign import javascript unsafe "(() => location.origin)"
  origin :: IO JSVal
foreign import javascript unsafe "(() => { const fragment=location.hash;history.replaceState(null,'',location.pathname+location.search);return fragment; })"
  takeFragment :: IO JSVal
foreign import javascript unsafe "((fragment,key) => new URLSearchParams(fragment.slice(1)).get(key)||'')"
  fragmentField :: JSVal -> JSVal -> IO JSVal
foreign import javascript unsafe "(() => Date.now()/1000)"
  now :: IO Double
foreign import javascript unsafe "((seconds) => new Date(seconds*1000).toLocaleString())"
  dateText :: Double -> IO JSVal
foreign import javascript unsafe "((labels,values,current) => { const el=document.getElementById('history');el.replaceChildren(new Option('Select saved order',''));for(let i=0;i<values.length;i++)el.add(new Option(labels[i],values[i]));el.value=current; })"
  historyOptions :: JSVal -> JSVal -> JSVal -> IO ()
foreign import javascript unsafe "((id) => { const el=document.getElementById(id);el.focus();el.select(); })"
  selectText :: JSVal -> IO ()
foreign import javascript interruptible "((value,done) => { if(!navigator.clipboard){done(false);return;}navigator.clipboard.writeText(value).then(()=>done(true),()=>done(false)); })"
  clipboard :: JSVal -> IO Bool
foreign import javascript interruptible "((path,method,token,body,done) => { const headers={'Content-Type':'application/json'};if(token)headers.Authorization='Bearer '+token;fetch(path,{method,headers,...(body?{body}:{}),signal:AbortSignal.timeout(30000)}).then(async response=>{const body=await response.text();if(body.length>65536)throw Error('response_too_large');done(JSON.stringify({ok:response.ok,status:response.status,body}));}).catch(()=>done(JSON.stringify({ok:false,status:0,body:'{\"error\":\"network_error\"}'}))); })"
  fetchJSON :: JSVal -> JSVal -> JSVal -> JSVal -> IO JSVal
foreign import javascript unsafe "((size) => { const canvas=document.getElementById('qr');canvas.width=canvas.height=(size+8)*6;const ctx=canvas.getContext('2d');ctx.fillStyle='white';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.fillStyle='black'; })"
  beginQR :: Int -> IO ()
foreign import javascript unsafe "((x,y) => document.getElementById('qr').getContext('2d').fillRect((x+4)*6,(y+4)*6,6,6))"
  qrModule :: Int -> Int -> IO ()
