(parameters => {
  'use strict';
  // Runs in an isolated Chrome world. No DOM reads, navigation, risk or score queries.
  const previous = globalThis.__ccguardRuntimeProbe;
  previous?.cancel?.();
  const controller = new AbortController();
  let peer = null;
  const result = { roundID: parameters.roundID, collectedAt: Date.now(),
    browserTimezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    dnsSafe: null, webrtcSafe: null, details: {}, complete: false };
  globalThis.__ccguardRuntimeProbe = { result, cancel() { controller.abort(); peer?.close(); } };
  const alive = () => !controller.signal.aborted && globalThis.__ccguardRuntimeProbe.result === result;
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const json = async path => {
    const response = await fetch(path, { cache: 'no-store', credentials: 'omit',
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  };
  const ipv4 = ip => typeof ip === 'string' && /^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip) &&
    ip.split('.').every(part => Number(part) <= 255 && String(Number(part)) === part);
  const privateIP = ip => {
    const [a,b] = ip.split('.').map(Number);
    return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
      (a === 100 && b >= 64 && b <= 127) || (a === 198 && (b === 18 || b === 19));
  };
  const dns = async () => {
    const token = crypto.randomUUID().replaceAll('-', '');
    for (let i=1; i<=2 && alive(); i++) {
      await new Promise(resolve => {
        const image = new Image();
        const timer = setTimeout(() => { image.src=''; resolve(); }, 2000);
        image.onload = image.onerror = () => { clearTimeout(timer);resolve(); };
        image.src=`https://${token}-${i}.d.ip.net.coffee/pixel.gif?_=${Date.now()}`;
      });
    }
    await wait(1500);
    let servers = null;
    for (let attempt=0; attempt<2 && alive(); attempt++) {
      const data = await json(`/api/dns/result/${token}`);
      if (!Array.isArray(data.dns_servers) || !data.dns_servers.every(ipv4)) throw new Error('DNS 结果格式无法识别');
      servers = data.dns_servers;
      if (servers.length) break;
      if (attempt === 0) await wait(1500);
    }
    if (!alive()) return;
    if (servers === null || servers.length > 16) throw new Error('DNS 结果暂未确认');
    if (!servers.length) {
      result.dnsSafe = true;
      result.details.dns = '本轮未观察到 DNS 出口（网站探测口径）';
      return;
    }
    const countries = await Promise.all(servers.map(async ip => {
      const geo = await json(`/api/geoip/${ip}`);
      const cc = typeof geo.country_code === 'string' ? geo.country_code.toLowerCase() : '';
      if (cc === 'cn' && alive()) { result.dnsSafe=false;result.details.dns='观察到中国 DNS 出口'; }
      if (!/^[a-z]{2}$/.test(cc)) throw new Error('DNS 归属地暂未确认');
      return cc;
    }));
    if (alive() && result.dnsSafe !== false) {
      result.dnsSafe = !countries.includes('cn');
      result.details.dns = '本轮 DNS 出口归属地：'+countries.join(', ');
    }
  };
  const rtc = async () => {
    if (typeof RTCPeerConnection === 'undefined') {
      result.webrtcSafe=true;result.details.webrtc='WebRTC 不可用，未暴露 UDP';return;
    }
    peer = new RTCPeerConnection({ iceServers: [
      { urls: 'stun:stun.l.google.com:19302' }, { urls: 'stun:stun.cloudflare.com:3478' }
    ] });
    const addresses = new Set();
    let complete = false;
    const gathering = new Promise(resolve => {
      const timer = setTimeout(resolve, 6000);
      peer.onicecandidate = event => {
        if (!alive()) { clearTimeout(timer);resolve();return; }
        if (!event.candidate) { complete=true;clearTimeout(timer);resolve();return; }
        // ICE candidate grammar places the candidate address at field 5, including mDNS/IPv6.
        const address = event.candidate.candidate.trim().split(/\s+/)[4];
        if (!address || address.endsWith('.local')) return;
        if (ipv4(address)) {
          if (!privateIP(address)) {
            addresses.add(address);
            if (address !== parameters.expectedIP) {
              result.webrtcSafe=false;result.details.webrtc='UDP 出口与指定 IP 不一致';
            }
          }
        } else if (address.includes(':') && !/^(fe80:|f[cd][0-9a-f]{2}:|::1$)/i.test(address)) {
          result.webrtcSafe=false;result.details.webrtc='观察到公共 IPv6 UDP 出口';
        }
      };
    });
    try {
      peer.createDataChannel('ccguard');
      await peer.setLocalDescription(await peer.createOffer());
      await gathering;
      if (!alive() || result.webrtcSafe === false) return;
      result.webrtcSafe=true;
      // Like the startup website, this is a bounded leak observation, not proof of STUN reachability.
      // A successfully started gathering window with no public address is not a script/network error.
      result.details.webrtc=addresses.size ? '本轮观察到的 UDP 出口一致' :
        (complete ? '本轮 ICE 完成，未观察到公共 UDP 出口' : '本轮观察窗口内未暴露公共 UDP（可能已禁用或阻断）');
    } finally { peer.close(); }
  };
  const service = async () => {
    const data=await json('/claude/status.json');
    const indicator=data.overall_indicator;
    const labels={none:'全部服务正常',minor:'轻微故障',major:'重大故障',critical:'严重故障',maintenance:'维护中'};
    result.details.service=labels[indicator] ?? '状态暂未确认';
  };
  Promise.allSettled([
    dns().catch(error => { if (alive() && result.dnsSafe !== false) result.details.dns=String(error.message); }),
    rtc().catch(error => { if (alive() && result.webrtcSafe !== false) result.details.webrtc=String(error.message); }),
    service().catch(() => { if (alive()) result.details.service='状态暂未获取'; })
  ]).then(() => { if (alive()) { result.collectedAt=Date.now();result.complete=true; } });
  return parameters.roundID;
})(/*PARAMETERS*/)
