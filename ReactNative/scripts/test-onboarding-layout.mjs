#!/usr/bin/env node
// Run production JSX styles through React Native's own Yoga engine. Content
// heights stand in for text/controls; the placement rules are read from source.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,readFileSync,readdirSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import ts from 'typescript';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const read=file=>readFileSync(path.join(root,file),'utf8');
const module=(source,require=()=>({}))=>{const context={exports:{},require};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,context);return context.exports;};
const tokens=module(read('src/generated/tokens.ts'));
const {foundation}=module(read('src/foundation.ts'),()=>tokens);
function declaration(file,name){const source=ts.createSourceFile(file,read(file),ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);return source.statements.find(node=>ts.isFunctionDeclaration(node)&&node.name.text===name).getText(source);}
const context={exports:{},foundation,View:'View',ScrollView:'ScrollView',React:{createElement:(type,props,...children)=>({type,props:props??{},children:children.flat().filter(Boolean)})}};
vm.runInNewContext(ts.transpileModule(declaration('src/window-layout.ts','windowLayout'),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,context);
vm.runInNewContext(ts.transpileModule(declaration('review/onboarding-scaffold.tsx','OnboardingStageLayout'),{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.React}}).outputText,context);
const flat=style=>Object.assign({},...(Array.isArray(style)?style.flat(Infinity):[style]).filter(Boolean));
const enums={flexDirection:{row:'YGFlexDirectionRow',column:'YGFlexDirectionColumn'},alignItems:{center:'YGAlignCenter'},alignSelf:{center:'YGAlignCenter'},justifyContent:{center:'YGJustifyCenter'},position:{absolute:'YGPositionTypeAbsolute'}};
const setters={width:'Width',height:'Height',maxWidth:'MaxWidth',minWidth:'MinWidth',flex:'Flex',flexGrow:'FlexGrow',flexShrink:'FlexShrink'};
function styles(name,style){return Object.entries(flat(style)).map(([key,value])=>{
  if(setters[key])return `YGNodeStyleSet${setters[key]}${typeof value==='string'?'Percent':''}(${name},${parseFloat(value)});`;
  if(enums[key])return `YGNodeStyleSet${key==='position'?'PositionType':key[0].toUpperCase()+key.slice(1)}(${name},${enums[key][value]});`;
  if(key==='gap')return `YGNodeStyleSetGap(${name},YGGutterAll,${value});`;
  if(key.startsWith('padding'))return `YGNodeStyleSetPadding(${name},YGEdge${key.slice(7)||'All'},${value});`;
  assert(['opacity'].includes(key),`Handle production style ${key} in this layout test.`);return '';
}).join('\n');}
const scenarios=[];
for(const [width,height] of [[402,874],[874,402],[768,1024],[1366,1024],[700,600],[320,600]])for(const welcome of [true,false])for(const contentHeight of [160,400,1200]){
  const view=context.exports.OnboardingStageLayout({width,height,welcome,source:{current:null},children:{type:'View',props:{style:{height:contentHeight}}}});
  assert.equal(view.type,'ScrollView','The complete scene must share one scroll owner.');
  let count=0;const named={};const lines=[];
  function node(tree){const name=`n${count++}`;lines.push(`auto ${name}=YGNodeNew();`,styles(name,tree.props.style));if(tree.props.testID)named[tree.props.testID]=name;
    (tree.children??[]).forEach((child,index)=>lines.push(`YGNodeInsertChild(${name},${node(child)},${index});`));return name;}
  const scroll=node({...view,props:{...view.props,style:{width,height}},children:[{type:'View',props:{style:view.props.contentContainerStyle},children:view.children}]});
  const content='n1',group=named['onboarding.composition'],source=named['onboarding.source.column'],pages=named['onboarding.pages.viewport'];
  scenarios.push(`{${lines.join('\n')}
    YGNodeCalculateLayout(${scroll},YGUndefined,YGUndefined,YGDirectionLTR);
    float contentHeight=YGNodeLayoutGetHeight(${content}),groupHeight=YGNodeLayoutGetHeight(${group});
    float groupY=YGNodeLayoutGetTop(${group}),groupX=YGNodeLayoutGetLeft(${group});
    check(contentHeight>=${height}-1,"Scroll content must fill the viewport.");
    check(near(groupY+groupHeight/2,contentHeight/2),"Scene must be vertically centered, including during overflow.");
    check(groupY>=23,"Overflow must keep the top of the scene reachable.");
    check(near(groupX+YGNodeLayoutGetWidth(${group})/2,${width}/2),"Scene must be horizontally centered.");
    check(near(YGNodeLayoutGetHeight(${pages}),${contentHeight}),"Long content must retain its intrinsic height.");
    ${!welcome&&width>height?`check(near(YGNodeLayoutGetTop(${source})+YGNodeLayoutGetHeight(${source})/2,YGNodeLayoutGetTop(${pages})+YGNodeLayoutGetHeight(${pages})/2),"Landscape mascot and page must share a vertical center.");`:''}
    ${!welcome&&width<=height?`check(YGNodeLayoutGetTop(${pages})>=YGNodeLayoutGetHeight(${source}),"Portrait mascot and content must not overlap.");`:''}
    std::printf("${width}x${height} ${welcome?'welcome':'step'} body=${contentHeight}: stage %.0f, scene y=%.0f h=%.0f\\n",contentHeight,groupY,groupHeight);
    YGNodeFreeRecursive(${scroll});
  }`);
}
const directory=mkdtempSync(path.join(tmpdir(),'lava-onboarding-yoga-'));
const yoga=path.join(root,'node_modules/react-native/ReactCommon/yoga');
const cppFiles=directory=>readdirSync(directory,{withFileTypes:true}).flatMap(entry=>entry.isDirectory()?cppFiles(path.join(directory,entry.name)):entry.name.endsWith('.cpp')?[path.join(directory,entry.name)]:[]);
try{
 const fixture=path.join(directory,'layout.cpp'),binary=path.join(directory,'layout');
 writeFileSync(fixture,`#include <yoga/Yoga.h>\n#include <cmath>\n#include <cstdio>\nint failures=0;bool near(float a,float b){return std::fabs(a-b)<1;}void check(bool ok,const char* message){if(!ok){std::printf("FAIL: %s\\n",message);failures++;}}\nint main(){${scenarios.join('\n')}return failures?1:0;}`);
 execFileSync(process.env.CXX??'c++',['-std=c++20','-O0',`-I${yoga}`,fixture,...cppFiles(path.join(yoga,'yoga')),'-o',binary],{stdio:'inherit'});
 execFileSync(binary,[],{stdio:'inherit'});
 console.log(`Passed ${scenarios.length} onboarding scenes using production JSX and real Yoga.`);
}finally{rmSync(directory,{recursive:true,force:true});}
