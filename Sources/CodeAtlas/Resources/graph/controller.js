(() => {
  'use strict';
  const status = document.getElementById('status');
  const canvas = document.getElementById('canvas');
  let legend = null;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let serial = 0, currentGeneration = 0, selected = null, fileIDs = {}, drag = null, dragged = false, zoomOpenArmed = true;
  let camera = {x: 0, y: 0, z: 1}, target = {...camera}, animation = 0, fitted = true;
  let renderQueue = Promise.resolve();
  const node = alias => canvas.querySelector(`g.node[data-atlas-id="${CSS.escape(alias)}"]`);
  const post = body => window.webkit.messageHandlers.atlas.postMessage(body);
  const message = text => { status.textContent = text; status.hidden = !text; };
  const paint = () => { canvas.style.transform = `translate(${camera.x}px,${camera.y}px) scale(${camera.z})`; };
  function tick() {
    const amount = reduced.matches || drag ? 1 : .28;
    for (const key of ['x','y','z']) camera[key] += (target[key] - camera[key]) * amount;
    if (Math.abs(camera.x-target.x)+Math.abs(camera.y-target.y)+Math.abs(camera.z-target.z)<.015) {
      camera = {...target}; animation = 0; paint(); return;
    }
    paint(); animation = requestAnimationFrame(tick);
  }
  function move(next, immediate=false) {
    target=next;
    if(immediate || reduced.matches) {cancelAnimationFrame(animation);animation=0;camera={...target};paint();}
    else if(!animation) animation=requestAnimationFrame(tick);
  }
  function fit(immediate=false) {
    const svg=canvas.querySelector('svg'); if(!svg) return;
    const w=Number(svg.getAttribute('width')),h=Number(svg.getAttribute('height'));
    if(!(w>0&&h>0)) return;
    const z=Math.max(.005,Math.min(1.6,(innerWidth-64)/w,(innerHeight-64)/h));
    fitted=true;move({x:(innerWidth-w*z)/2,y:(innerHeight-h*z)/2,z},immediate);
  }
  function select(alias) {
    selected=alias;canvas.querySelectorAll('.node.selected').forEach(n=>n.classList.remove('selected'));
    if(alias) node(alias)?.classList.add('selected');
  }
  function activate(element) {
    if(!element || canvas.classList.contains('loading'))return;
    post({type:'select',alias:element.dataset.atlasId,generation:currentGeneration});
  }
  mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'base',maxTextSize:2000000,maxEdges:20000,
    flowchart:{htmlLabels:false,curve:'basis',nodeSpacing:22,rankSpacing:72,useMaxWidth:false},
    themeVariables:{primaryColor:'#162d39',primaryBorderColor:'#365563',primaryTextColor:'#e2f1f2',lineColor:'#658b99',secondaryColor:'#1e283e',tertiaryColor:'#131d29',fontFamily:'-apple-system, sans-serif',fontSize:'14px'}});
  let readerActive=false,openAfter=0;
  function openNode(alias) {
    const n=node(alias),fileID=fileIDs[alias];
    if(readerActive||!n||!Number.isInteger(fileID))return;
    readerActive=true;zoomOpenArmed=false;move({...camera},true);
    const r=n.getBoundingClientRect();
    post({type:"open",fileID,generation:currentGeneration,rect:{x:r.x,y:r.y,width:r.width,height:r.height}});
  }
  window.Atlas = {
    open:openNode,
    readerClosed(){readerActive=false;zoomOpenArmed=false;openAfter=performance.now()+650;},
    status:message,
    clear() {
      ++serial;currentGeneration=0;selected=null;readerActive=false;zoomOpenArmed=true;canvas.replaceChildren();canvas.classList.remove('loading');if(legend)legend.hidden=true;
      cancelAnimationFrame(animation);animation=0;message('Choose a folder to explore its connections.');
    },
    select, fit:()=>fit(),
    focus(alias) {
      const n=node(alias);if(!n)return;
      const r=n.getBoundingClientRect();fitted=false;
      move({...camera,x:camera.x+innerWidth/2-r.left-r.width/2,y:camera.y+innerHeight/2-r.top-r.height/2});select(alias);
    },
    verify:()=>({ready:true,svgCount:canvas.querySelectorAll('svg').length,nodeCount:canvas.querySelectorAll('g.node[data-atlas-id]').length,selected,camera:{...camera},width:canvas.querySelector('svg')?.viewBox.baseVal.width,height:canvas.querySelector('svg')?.viewBox.baseVal.height,loading:canvas.classList.contains('loading'),status:status.hidden?'':status.textContent}),
    verifyZoomOpen() {
      const n=canvas.querySelector('g.node[data-atlas-id]');if(!n)return;
      const r=n.getBoundingClientRect();move({x:0,y:0,z:2.3},true);
      zoomOpenArmed=true;openAfter=0;
      n.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaY:8,clientX:r.x+r.width/2,clientY:r.y+r.height/2}));
    },
    verifySelect:()=>activate(canvas.querySelector('g.node[data-atlas-id]')),
    render(encoded) {
    const mine=++serial;
      canvas.classList.add('loading');message('Drawing connections…');
      renderQueue=renderQueue.catch(()=>{}).then(async()=>{
        if(mine!==serial)return;
        try {
          const bytes=Uint8Array.from(atob(encoded),x=>x.charCodeAt(0));
          const data=JSON.parse(new TextDecoder().decode(bytes));
          if(!data.aliases.length) {canvas.replaceChildren();canvas.classList.remove('loading');if(legend)legend.hidden=true;message('No matching files. Try a broader search.');return;}
          const out=await mermaid.render('atlasGraph'+mine,data.source);
          if(mine!==serial)return;
          canvas.innerHTML=out.svg;
          if(!legend){legend=document.createElement('div');legend.id='legend';legend.setAttribute('role','note');document.body.append(legend);}
          legend.textContent='Dashed edges are lexical import candidates · labeled edges are links or evidence';
          legend.hidden=false;
          const svg=canvas.querySelector('svg'),box=svg.viewBox.baseVal;
          svg.setAttribute('width',String(box.width));svg.setAttribute('height',String(box.height));
          svg.style.maxWidth='none';svg.style.width=box.width+'px';svg.style.height=box.height+'px';
          fileIDs=data.fileIDs||{};
          const aliases=new Set(data.aliases);
          canvas.querySelectorAll('g.node').forEach(n=>{
            const match=n.id.match(/^flowchart-(n\d+)-/),alias=match&&match[1];
            if(!aliases.has(alias))return;
            n.dataset.atlasId=alias;n.setAttribute('tabindex','0');n.setAttribute('role','button');
            n.setAttribute('aria-label',data.titles[alias]||'Graph item');
          });
          currentGeneration=data.generation;select(data.selected||null);canvas.classList.remove('loading');fit(true);message('');
          post({type:'status',status:'Graph ready'});
        } catch(error) {
          if(mine!==serial)return;
          canvas.replaceChildren();canvas.classList.remove('loading');if(legend)legend.hidden=true;message('This graph could not be drawn. Try a narrower file search.');
          post({type:'status',status:'Graph unavailable'});
        }
      });
    }
  };
  document.addEventListener('click',event=>{
    if(dragged){dragged=false;return;}activate(event.target.closest('g.node[data-atlas-id]'));
  });
  document.addEventListener('dblclick',event=>{
    const n=event.target.closest('g.node[data-atlas-id]');
    if(!n)return;
    const fileID=fileIDs[n.dataset.atlasId];
    if(Number.isInteger(fileID))openNode(n.dataset.atlasId);
    else Atlas.focus(n.dataset.atlasId);
  });
  document.addEventListener('keydown',event=>{
    if(event.key==='Escape'){fit();return;}
    if(event.key==='Enter'||event.key===' '){const n=event.target.closest('g.node[data-atlas-id]');if(n){event.preventDefault();activate(n);}}
  });
  document.addEventListener('wheel',event=>{
    event.preventDefault();fitted=false;
    const delta=event.deltaY*(event.deltaMode===1?16:1),factor=Math.exp(Math.max(-.35,Math.min(.35,delta*.002)));
    const z=Math.max(.005,Math.min(6,target.z*factor)),ratio=z/target.z;
    move({x:event.clientX-(event.clientX-target.x)*ratio,y:event.clientY-(event.clientY-target.y)*ratio,z});
    const hit=event.target.closest('g.node[data-atlas-id]'),fileID=hit&&fileIDs[hit.dataset.atlasId];
    if(delta<0&&performance.now()>openAfter)zoomOpenArmed=true;
    if(delta>0&&z>2.2&&zoomOpenArmed&&performance.now()>openAfter&&Number.isInteger(fileID))openNode(hit.dataset.atlasId);
  },{passive:false});
  document.addEventListener('pointerdown',event=>{
    if(event.button!==0)return;
    drag={x:event.clientX,y:event.clientY,start:{...camera}};dragged=false;canvas.classList.add('drag');
  });
  document.addEventListener('pointermove',event=>{
    if(!drag)return;
    if(Math.hypot(event.clientX-drag.x,event.clientY-drag.y)>5)dragged=true;
    if(!dragged)return;fitted=false;
    move({...drag.start,x:drag.start.x+event.clientX-drag.x,y:drag.start.y+event.clientY-drag.y},true);
  });
  const end=()=>{drag=null;canvas.classList.remove('drag');};
  document.addEventListener('pointerup',end);document.addEventListener('pointercancel',end);
  addEventListener('blur',end);addEventListener('resize',()=>{if(fitted)fit(true);});
})();
