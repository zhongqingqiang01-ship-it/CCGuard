(() => {
  "use strict";
  const text = (element) => element ? (element.innerText || element.textContent || "").replace(/\s+/g, " ").trim() : "";
  const byID = (id) => document.getElementById(id);
  const rows = (id) => {
    const result = {};
    const root = byID(id);
    if (root) root.querySelectorAll(".risk-row").forEach((row) => {
      const label = text(row.querySelector(".risk-label"));
      if (label) result[label] = text(row.querySelector(".risk-value"));
    });
    return result;
  };
  const visible = (element) => {
    if (!element || element.hidden) return false;
    for (let current = element; current; current = current.parentElement) {
      const style = getComputedStyle(current);
      if (style.display === "none" || style.visibility === "hidden") return false;
    }
    return true;
  };
  const parseIP = (value) => {
    const match = value.match(/^(\d{1,3}(?:\.\d{1,3}){3})$/);
    if (!match) return null;
    return match[1].split(".").every((part) => Number(part) <= 255 && String(Number(part)) === part) ? match[1] : null;
  };
  const booleanFrom = (value, yes, no) => yes.includes(value) ? true : no.includes(value) ? false : null;
  const props = rows("propsContent"), security = rows("securityContent");
  const dns = rows("dnsLeakContent"), webrtc = rows("udpLeakContent");
  const device = rows("deviceContent"), availability = rows("claudeAvailContent");
  const raw = {
    chinaIP: text(byID("ipAddrCN")), cloudflareIP: text(byID("ipAddr")), claudeIP: text(byID("ipAddrClaude")),
    score: text(byID("gaugeScore")), country: props["地区"] || "", residential: props["IP 属性"] || "",
    regionSupport: text(byID("claudeRegionSupport")), regionWarning: visible(byID("regionWarn")) ? text(byID("regionWarn")) : "",
    vpn: security["VPN"] || "", proxy: security["代理 (Proxy)"] || "", tor: security["Tor"] || "",
    crawler: security["机器人 (Crawler)"] || "", abuser: security["滥用记录"] || "",
    dns: dns["状态"] || "", webrtc: webrtc["状态"] || "", timezone: device["时区"] || "",
    language: device["语言"] || "", claudeAvailability: availability["claude.ai"] || "",
    anthropicAvailability: availability["anthropic.com"] || "", serviceStatus: availability["Claude服务状态"] || ""
  };
  const scoreText = text(byID("gaugeScore")?.querySelector("span"));
  const score = /^\d+(?:\.\d+)?$/.test(scoreText) ? Number(scoreText) : null;
  const reachable = (value) => /^(正常|良好|较慢) \d+ms$/.test(value) ? true : value === "不可访问" ? false : null;
  const residential = /^家庭住宅IP(?:\s*\([^)]*\))?$/.test(raw.residential) ? true : /^机房IP(?:\s*\([^)]*\))?$/.test(raw.residential) ? false : null;
  const timezoneConsistent = raw.timezone.startsWith("时区一致 ") ? true : raw.timezone.includes("时区不一致") || raw.timezone.includes("不推荐使用中国大陆时区") ? false : null;
  const sourceFailures = [];
  for (const key of ["chinaIP", "cloudflareIP", "claudeIP"]) {
    if (/获取失败|检测失败|请求失败|无法获取/.test(raw[key])) sourceFailures.push(`${key} 获取失败`);
  }
  return {
    schemaVersion: 1, url: location.href, timeOrigin: performance.timeOrigin,
    collectedAt: Date.now(), readyState: document.readyState,
    browserTimezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "",
    ipv6Warning: visible(byID("ipv6Warn")), raw, sourceFailures,
    score, chinaIP: parseIP(raw.chinaIP), cloudflareIP: parseIP(raw.cloudflareIP), claudeIP: parseIP(raw.claudeIP),
    country: raw.country || null, residential,
    regionSupported: raw.regionWarning ? false : booleanFrom(raw.regionSupport, ["正常"], ["不可访问", "不支持"]),
    vpn: booleanFrom(raw.vpn, ["VPN"], ["未检测到"]),
    proxy: booleanFrom(raw.proxy, ["代理"], ["未检测到"]),
    tor: booleanFrom(raw.tor, ["Tor"], ["未检测到"]),
    crawler: booleanFrom(raw.crawler, ["是"], ["否"]),
    abuser: booleanFrom(raw.abuser, ["有记录"], ["无记录"]),
    dnsSafe: booleanFrom(raw.dns, ["未检测到泄露", "DNS 加密或未暴露出口"], ["可能泄露", "检测到泄露"]),
    webrtcSafe: booleanFrom(raw.webrtc, ["WebRTC 已禁用或无泄露", "未检测到泄露"], ["可能泄露", "检测到泄露"]),
    timezoneConsistent, claudeReachable: reachable(raw.claudeAvailability),
    anthropicReachable: reachable(raw.anthropicAvailability),
    serviceHealthy: booleanFrom(raw.serviceStatus, ["全部服务正常"], ["轻微故障", "重大故障", "严重故障", "维护中", "服务异常"])
  };
})()
