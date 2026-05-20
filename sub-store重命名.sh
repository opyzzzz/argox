function operator(proxies) {
  return proxies.map(p => {
    // 1. 安全提取地域国家代码（处理 "JP-XTOM" 或 "JP"）
    let name = p.name || "";
    let country = "UN"; 
    if (name.includes("-")) {
      country = name.split("-")[0].toUpperCase();
    } else {
      country = name.substring(0, 2).toUpperCase();
    }

    // 2. 国家代码转换为大写国旗 Emoji
    let flag = "";
    if (/^[A-Z]{2}$/.test(country)) {
      flag = country.split('').map(char => String.fromCodePoint(char.charCodeAt(0) + 127397)).join('') + " ";
    }

    // 3. 深度分析节点协议类型与传输层（严格适配老王新版 inbound 规则）
    let typeStr = "";
    let type = p.type ? p.type.toLowerCase() : "";
    let network = p.network ? p.network.toLowerCase() : "";
    let flow = p.flow ? p.flow.toLowerCase() : "";
    let isArgo = false;

    // 【逻辑修正】优先锁定真正的传输网络
    if (network === "ws") {
      typeStr = "Argo";
      isArgo = true;
    } else if (network === "grpc") {
      typeStr = "Reality-gRPC";
    } else if (network === "xhttp" || p["xhttp-opts"]) {
      typeStr = "Reality-xHTTP";
    } else if (flow.includes("vision")) {
      typeStr = "Reality-Vision";
    } else if (type === "vless" || type === "vmess") {
      typeStr = "Reality";
    } else {
      typeStr = type.toUpperCase();
    }

    // 4. 【全网首发·深度容错】安全提取多协议共享的统一 UUID 密码尾段
    let uuidTail = "";
    // 完美兼容 VLESS(uuid) 和新版 Base64 解密后的 VMess(id)
    let rawUuid = p.uuid || p.id || "";
    if (rawUuid && rawUuid.length >= 4) {
      uuidTail = rawUuid.substring(rawUuid.length - 4).toUpperCase();
    }

    // 5. 根据特征码建立完全同步、毫无割裂感的命名尾缀
    let ipId = "";
    if (uuidTail) {
      if (isArgo) {
        // 精准检测网络路径，区别单机双通道（Vless / VMess）
        let path = "";
        if (p['ws-opts'] && p['ws-opts'].path) {
          path = p['ws-opts'].path.toLowerCase();
        }
        let pathTag = path.includes("vless") ? "V" : (path.includes("vmess") ? "M" : "T");
        ipId = ` .${uuidTail}-${pathTag}`;
      } else {
        // 普通 Reality 直连节点，全量拉齐使用同一台物理机的 UUID 标识
        ipId = ` .${uuidTail}`;
      }
    } else {
      // 极端异常兜底：未成功读取到密钥时回退到 IP 尾段去重
      if (p.server && !p.server.includes(":")) {
        ipId = ` .${p.server.split(".").pop()}`;
      }
    }

    // 6. 完全重写节点名称
    p.name = `自建- ${flag}${country}${ipId} [${typeStr}]`;
    
    return p;
  });
}
