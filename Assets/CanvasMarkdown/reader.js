/* Local, virtualized Markdown transcript. No source executes, no network requests. */
"use strict";
(() => {
  const main = document.getElementById("messages");
  let token = "", rows = [], initialized = false, observer, releaseObserver, resizeObserver;
  let pending = new Set(), wanted = new Set(), resident = new Map(), heights = new Map();
  let serial = Promise.resolve(), stateTimer, lastAnchor = {index:0,delta:0}, oldWidth = innerWidth;
  let imageCounter=0;const imageWanted=new Map(), imagePending=new Set();
  let themeEpoch=0,themeTimer,hasTheme=false,diagramCounter=0;
  const send = (type, fields = {}) => window.webkit.messageHandlers.canvas.postMessage({type,token,...fields});
  function imageUnavailable(img,phase) {const note=document.createElement("p");note.className="notice";note.textContent="Image not available";img.replaceWith(note);send("image-failure",{phase});}
  function displayImage(placeholder,src,saved=false) {
    const img=new Image();img.alt=placeholder.dataset.alt||"Image attachment";
    img.addEventListener("error",()=>imageUnavailable(img,"browser-decode"));
    img.src=src;
    if(saved){const figure=document.createElement("figure"),caption=document.createElement("figcaption");caption.className="notice";caption.textContent="Saved image copy";figure.append(img,caption);placeholder.replaceWith(figure);}
    else placeholder.replaceWith(img);
  }
  function pumpImages() {
    for(const [id,img] of imageWanted) {
      if(!img.isConnected){imageWanted.delete(id);continue;}
      if(imagePending.size>=2)break;
      if(imagePending.has(id))continue;
      imagePending.add(id);send("image",{id,path:img.dataset.canvasSrc});
    }
  }
  const imageObserver=new IntersectionObserver(entries=>{
    for(const e of entries) {if(e.isIntersecting)imageWanted.set(e.target.id,e.target);else imageWanted.delete(e.target.id);}
    pumpImages();
  },{rootMargin:"400px 0px"});
  const topOf = i => rows[i]?.element.offsetTop ?? 0;
  function anchor() {
    if (!rows.length) return {index:0,delta:0};
    let lo=0, hi=rows.length-1;
    while (lo<hi) { const mid=(lo+hi)>>1, el=rows[mid].element; if (el.offsetTop+el.offsetHeight<scrollY) lo=mid+1; else hi=mid; }
    return {index:lo,delta:scrollY-topOf(lo)};
  }
  function restore(a,bottom=false) { scrollTo(0,bottom ? document.documentElement.scrollHeight : topOf(a.index)+a.delta); }
  function state() {
    stateTimer=undefined; lastAnchor=anchor();
    send("state",{y:scrollY,anchor:lastAnchor.index,delta:lastAnchor.delta,heights:[...heights].map(([index,height])=>({index,height}))});
    heights.clear();
  }
  function scheduleState() { if (!stateTimer) stateTimer=setTimeout(state,80); }
  function measure(i) { const h=rows[i].element.getBoundingClientRect().height; rows[i].height=h; heights.set(i,h); scheduleState(); }
  function pump() {
    const batch=[...wanted].filter(i=>!pending.has(i)&&!resident.has(i)).slice(0,Math.max(0,4-pending.size));
    if (!batch.length) return; batch.forEach(i=>pending.add(i)); send("need",{indices:batch});
  }
  function unload(i) {
    const row=rows[i]; if (!row || !resident.has(i)) return;
    const a=anchor(), bottom=document.documentElement.scrollHeight-scrollY-innerHeight<2;
    row.height=row.element.getBoundingClientRect().height;
    row.body.querySelectorAll(".canvas-image[id]").forEach(img=>{imageObserver.unobserve(img);imageWanted.delete(img.id);});
    row.element.style.height=`${row.height}px`; row.body.replaceChildren();
    resident.delete(i); restore(a,bottom);
  }
  function budget() {
    let bytes=[...resident.values()].reduce((a,b)=>a+b,0);
    if (bytes<=4*1024*1024) return;
    const far=[...resident.keys()].filter(i=>!wanted.has(i)).sort((a,b)=>Math.abs(topOf(b)-scrollY)-Math.abs(topOf(a)-scrollY));
    for (const i of far) { bytes-=resident.get(i); unload(i); if(bytes<=4*1024*1024) break; }
  }
  function safeLink(href) { return /^(https?:|mailto:|codex:\/\/threads\/|file:|\/|#)/i.test(href||""); }
  function decorate(body,index) {
    body.querySelectorAll("[data-annotation]").forEach(el=>{el.id=`annotation-${index}-${el.dataset.annotation}`;});
    body.querySelectorAll("h1,h2,h3,h4,h5,h6").forEach((heading,n)=>{heading.dataset.anchor=heading.textContent.toLowerCase().replace(/[^\p{L}\p{N} _-]/gu,"").replace(/\s+/g,"-");heading.id=`m${index}-heading-${n}`;});
    body.querySelectorAll("a").forEach(a=>{ const href=a.getAttribute("href"); if(!safeLink(href)){a.removeAttribute("href");a.classList.add("disabled");} });
    body.querySelectorAll(".canvas-image").forEach(img=>{
      const src=img.dataset.canvasSrc||"", alt=img.dataset.alt||"Image";
      if (/^(\/|file:)/.test(src)) { img.id=`image-${++imageCounter}`;imageObserver.observe(img); }
      else if (/^data:image\/(png|jpeg|gif|webp);base64,/i.test(src)) { displayImage(img,src); }
      else if (/^https?:/i.test(src)) {
        const link=document.createElement("a");link.className="image-link";link.textContent=alt+" — open image";
        if(safeLink(src))link.setAttribute("href",src);img.replaceWith(link);
      } else imageUnavailable(img,"unsupported-source");
    });
    body.querySelectorAll("table").forEach(table=>{const box=document.createElement("div");box.className="table-scroll";table.replaceWith(box);box.append(table);});
    body.querySelectorAll("pre>code").forEach(code=>{
      const pre=code.parentElement, language=[...code.classList].find(c=>c.startsWith("language-"))?.slice(9)||"text";
      const box=document.createElement("div");box.className="code-block";
      const bar=document.createElement("div");bar.className="code-bar";
      const label=document.createElement("span");label.textContent=language;
      const copy=document.createElement("button");copy.textContent="Copy code";copy.type="button";
      copy.addEventListener("click",()=>send("copy",{text:code.textContent}));bar.append(label,copy);
      pre.replaceWith(box);box.append(bar,pre);
      if(language.toLowerCase()==="mermaid") {
        serial=serial.then(()=>diagram(box,pre,code,index)).catch(()=>{});
      } else if(code.textContent.length<128*1024 && window.hljs?.getLanguage(language)) {
        try{window.hljs.highlightElement(code);}catch{}
      }
    });
    body.querySelectorAll("x-equation").forEach(el=>{
      const display=el.getAttribute("type")==="display"; if(display)el.classList.add("math-display");
      try{window.katex.render(el.textContent,el,{displayMode:display,throwOnError:false,trust:false,strict:"ignore",maxExpand:500,maxSize:20});}catch{}
    });
    // The saved text can contain citation tokens without their source metadata.
    const walk=document.createTreeWalker(body,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest("pre,code,.katex") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT});
    const nodes=[];while(walk.nextNode())nodes.push(walk.currentNode);
    for(const node of nodes) if(/:codex-annotation\{index="\d+"\}/.test(node.textContent)) {
      const fragment=document.createDocumentFragment(), regex=/:codex-annotation\{index="(\d+)"\}/g;let previous=0;
      for(const match of node.textContent.matchAll(regex)){fragment.append(document.createTextNode(node.textContent.slice(previous,match.index)));const span=document.createElement("span");span.className="annotation-reference";span.textContent=`[${match[1]}]`;span.setAttribute("aria-label",`Annotation ${match[1]}`);fragment.append(span);previous=match.index+match[0].length;}
      fragment.append(document.createTextNode(node.textContent.slice(previous)));node.replaceWith(fragment);
    }
    walk.currentNode=body;const citationNodes=[];while(walk.nextNode())citationNodes.push(walk.currentNode);
    for(const node of citationNodes) if(/\uE200(?:cite|filecite|filenavlist)\uE202/.test(node.textContent)) {
      const parts=node.textContent.split(/(\uE200(?:cite|filecite|filenavlist)\uE202[^\uE201]*\uE201)/g), fragment=document.createDocumentFragment();
      parts.forEach(part=>{if(part.startsWith("\uE200")){const span=document.createElement("span");span.className="citation";span.textContent="Citation · source details unavailable";fragment.append(span);}else fragment.append(document.createTextNode(part));});node.replaceWith(fragment);
    }
  }
  let mermaidPromise;
  function mermaid() {
    if(!mermaidPromise)mermaidPromise=Promise.reject(new Error("Diagram renderer is not bundled"));
    return mermaidPromise;
  }
  async function diagram(box,pre,code,index) {
    if(!box.isConnected)return;
    box.querySelectorAll(".diagram-notice").forEach(node=>node.remove());
    const epoch=themeEpoch;
    const source=code.textContent;
    if(source.length>24_000 || source.split("\n").length>300){const note=document.createElement("p");note.className="notice diagram-notice";note.textContent="Large diagram — source shown.";box.prepend(note);return;}
    try {
      const m=await mermaid();if(!box.isConnected||epoch!==themeEpoch)return;
      const style=getComputedStyle(document.documentElement),color=name=>style.getPropertyValue("--"+name).trim();
      m.initialize({startOnLoad:false,securityLevel:"strict",maxTextSize:24_000,maxEdges:400,theme:"base",themeVariables:{darkMode:!document.documentElement.classList.contains("light"),background:color("assistant"),primaryColor:color("diagram-fill")||color("assistant"),primaryTextColor:color("ink"),primaryBorderColor:color("line"),lineColor:color("muted"),textColor:color("ink"),secondaryColor:color("code"),secondaryTextColor:color("ink"),tertiaryColor:color("user"),tertiaryTextColor:color("ink"),edgeLabelBackground:color("assistant")},flowchart:{htmlLabels:false},suppressErrorRendering:true,fontFamily:"-apple-system,BlinkMacSystemFont,sans-serif"});
      const result=await m.render(`diagram-${index}-${++diagramCounter}`,source);if(!box.isConnected||epoch!==themeEpoch)return;
      const a=anchor(), bottom=document.documentElement.scrollHeight-scrollY-innerHeight<2;
      const previous=box.querySelector(".diagram-source"),wasOpen=previous?.open||false;
      box.querySelector(".diagram")?.remove();if(previous){box.append(pre);previous.remove();}
      const drawing=document.createElement("div");drawing.className="diagram";drawing.innerHTML=result.svg;
      drawing.querySelectorAll("a").forEach(a=>a.removeAttribute("href"));
      const details=document.createElement("details");details.className="diagram-source";
      details.open=wasOpen;
      const summary=document.createElement("summary");summary.textContent="Diagram source";details.append(summary,pre);box.append(drawing,details);
      measure(index);restore(a,bottom);
    } catch {if(box.isConnected&&epoch===themeEpoch){const note=document.createElement("p");note.className="notice diagram-notice";note.textContent="Diagram could not render — source shown.";if(pre.parentElement!==box){const details=pre.closest("details");box.append(pre);details?.remove();}box.querySelector(".diagram")?.remove();box.insertBefore(note,pre);measure(index);}}
  }
  window.canvas={
    configure(config) {
      if(initialized)return; initialized=true;token=config.token;
      this.theme(config.dark,config.colors);
      const saved=new Map(config.heights.map(h=>[h.index,h.height]));
      const fragment=document.createDocumentFragment();
      rows=config.rows.map((row,i)=>{
        const element=document.createElement("article");element.className=row.role==="YOU"?"user":"assistant";element.dataset.index=i;
        const heading=document.createElement("header");heading.textContent=row.role+" · "+row.date;heading.id=`m${i}-label`;
        element.setAttribute("aria-labelledby",heading.id);element.dataset.source=row.source;
        const body=document.createElement("div");body.className="body";body.textContent="Loading message…";
        element.append(heading,body);const height=saved.get(i)||88;element.style.height=`${height}px`;
        fragment.append(element);return {element,body,height};
      });main.replaceChildren(fragment);
      observer=new IntersectionObserver(entries=>{for(const e of entries){const i=Number(e.target.dataset.index);if(e.isIntersecting)wanted.add(i);else wanted.delete(i);}pump();},{rootMargin:"800px 0px"});
      releaseObserver=new IntersectionObserver(entries=>{for(const e of entries)if(!e.isIntersecting)unload(Number(e.target.dataset.index));},{rootMargin:"2400px 0px"});
      resizeObserver=new ResizeObserver(entries=>{for(const e of entries)if(resident.has(Number(e.target.dataset.index)))measure(Number(e.target.dataset.index));});
      requestAnimationFrame(()=>{
        if(config.hasAnchor)restore({index:Math.min(rows.length-1,config.anchor),delta:config.delta});else scrollTo(0,config.y);
        lastAnchor=anchor();
        rows.forEach(row=>{observer.observe(row.element);releaseObserver.observe(row.element);resizeObserver.observe(row.element);});
        scheduleState();
      });
    },
    theme(dark,colors={}) {
      const root=document.documentElement;root.classList.toggle("light",!dark);
      for(const [name,value] of Object.entries(colors))if(/^[a-z-]+$/.test(name)&&/^#[0-9a-f]{6}$/i.test(value))root.style.setProperty("--"+name,value);
      if(hasTheme){themeEpoch++;clearTimeout(themeTimer);themeTimer=setTimeout(()=>{
        document.querySelectorAll("pre>code.language-mermaid").forEach(code=>{const box=code.closest(".code-block"),index=Number(code.closest("article").dataset.index);if(box)serial=serial.then(()=>diagram(box,code.parentElement,code,index)).catch(()=>{});});
      },300);}
      hasTheme=true;
    },
    image(id,data,saved) {
      imagePending.delete(id);imageWanted.delete(id);
      const img=document.getElementById(id);
      if(img?.classList.contains("canvas-image")){imageObserver.unobserve(img);if(data)displayImage(img,data,saved);else imageUnavailable(img,"native-read");}
      pumpImages();
    },
    message(index,html) {
      const row=rows[index];if(!row)return;
      pending.delete(index);
      const a=anchor(), bottom=document.documentElement.scrollHeight-scrollY-innerHeight<2;
      const empty=!html.trim();row.element.classList.toggle("context-only",empty);row.element.setAttribute("aria-hidden",String(empty));row.element.style.height="auto";
      const template=document.createElement("template");template.innerHTML=html;
      template.content.querySelectorAll("img").forEach(img=>{
        const placeholder=document.createElement("div");placeholder.className="canvas-image notice";placeholder.dataset.canvasSrc=img.getAttribute("data-canvas-src")||"";placeholder.dataset.alt=img.alt;placeholder.textContent="Loading image…";img.replaceWith(placeholder);
      });
      row.body.replaceChildren(template.content);resident.set(index,html.length*2);
      const origin=row.body.querySelector(".message-origin")?.dataset.label;if(origin)row.element.querySelector("header").textContent=row.element.querySelector("header").textContent.replace(/^[^·]+/,origin+" ");
      decorate(row.body,index);measure(index);restore(a,bottom);budget();pump();
    }
  };
  addEventListener("scroll",()=>{lastAnchor=anchor();scheduleState();},{passive:true});
  addEventListener("resize",()=>{if(innerWidth!==oldWidth){oldWidth=innerWidth;restore(lastAnchor);}scheduleState();});
  addEventListener("click",event=>{
    const a=event.target.closest("a");if(!a)return;event.preventDefault();const href=a.getAttribute("href");if(!href)return;
    if(href.startsWith("#")){let key;try{key=decodeURIComponent(href.slice(1));}catch{return;}const el=[...a.closest("article").querySelectorAll("[data-anchor]")].find(h=>h.dataset.anchor===key)||document.getElementById(key);el?.scrollIntoView();}
    else send("link",{href});
  });
  addEventListener("contextmenu",event=>{event.preventDefault();send("context",{x:event.clientX,y:event.clientY,selection:getSelection()?.toString()||""});});
  send("ready");
})();
