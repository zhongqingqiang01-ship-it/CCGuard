import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const template=fs.readFileSync(new URL('../Resources/background-probe.js',import.meta.url),'utf8');
async function run({dns=[],country='us',dnsError=false,rtc='complete',address=null,geoError=false,service='none',serviceError=false}={}) {
  const calls=[];let canceled=0;
  const context={ Date,Intl,Promise,Set,Error,AbortController,AbortSignal,
    crypto:{randomUUID:()=> 'fresh-dns-token'},
    setTimeout:(fn,ms)=>setTimeout(fn,ms===6000 ? 30 : 0),clearTimeout,
    fetch:async path=>{
      calls.push(path);
      if(path==='/claude/status.json') {
        if(serviceError) throw new Error('service timeout');
        return {ok:true,json:async()=>({overall_indicator:service})};
      }
      if(path.startsWith('/api/dns/result/')) {
        if(dnsError) throw new Error('network timeout');
        return {ok:true,json:async()=>({dns_servers:dns})};
      }
      if(path.startsWith('/api/geoip/')) {
        if(geoError) throw new Error('geo timeout');
        return {ok:true,json:async()=>({country_code:country})};
      }
      throw new Error('unexpected endpoint '+path);
    },
    Image:class {set src(value) {if(value) queueMicrotask(()=>this.onerror?.());}},
    RTCPeerConnection:class {
      createDataChannel() {}
      async createOffer(){if(rtc==='error')throw new Error('RTC setup failed');return {type:'offer'};}
      async setLocalDescription(){
        if(address) this.onicecandidate({candidate:{candidate:`candidate:1 1 udp 123 ${address} 4321 typ srflx`}});
        if(rtc==='complete') this.onicecandidate({candidate:null});
      }
      close(){canceled++;}
    }
  };
  vm.createContext(context);
  const parameters={roundID:'fresh-round',expectedIP:'192.0.2.10'};
  vm.runInContext(template.replace('/*PARAMETERS*/',JSON.stringify(parameters)),context);
  for(let i=0;i<150&&!context.__ccguardRuntimeProbe.result.complete;i++) await new Promise(r=>setTimeout(r,2));
  const result=JSON.parse(JSON.stringify(context.__ccguardRuntimeProbe.result));
  assert.equal(result.complete,true);
  assert.equal(result.roundID,'fresh-round');
  assert.ok(calls.every(path=>path.startsWith('/api/dns/result/')||path.startsWith('/api/geoip/')||path==='/claude/status.json'));
  assert.ok(!calls.some(path=>/iprisk|claude-page|score/.test(path)));
  assert.ok(canceled>0,'RTC must be closed');
  return result;
}
let result=await run();assert.equal(result.dnsSafe,true);assert.equal(result.webrtcSafe,true);
result=await run({dnsError:true});assert.equal(result.dnsSafe,null);assert.equal(result.webrtcSafe,true);
result=await run({dns:['192.0.2.53'],country:'cn'});assert.equal(result.dnsSafe,false);
result=await run({dns:['192.0.2.53'],geoError:true});assert.equal(result.dnsSafe,null);
result=await run({dns:['unknown']});assert.equal(result.dnsSafe,null);
result=await run({rtc:'timeout'});assert.equal(result.webrtcSafe,true);
result=await run({rtc:'error'});assert.equal(result.webrtcSafe,null);
result=await run({address:'192.0.2.11'});assert.equal(result.webrtcSafe,false);
result=await run({address:'192.0.2.10'});assert.equal(result.webrtcSafe,true);
result=await run({address:'172.200.0.1'});assert.equal(result.webrtcSafe,false);
result=await run({address:'172.16.0.1'});assert.equal(result.webrtcSafe,true);
result=await run({address:'2001:db8::1'});assert.equal(result.webrtcSafe,false);
result=await run({service:'major'});assert.equal(result.details.service,'重大故障');assert.equal(result.dnsSafe,true);
result=await run({serviceError:true});assert.equal(result.details.service,'状态暂未获取');assert.equal(result.dnsSafe,true);
console.log('Background probe: 14 cases passed; no navigation, DOM reads, or reputation requests');
