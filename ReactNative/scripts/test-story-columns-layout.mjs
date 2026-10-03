#!/usr/bin/env node
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,readFileSync,readdirSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';
import vm from 'node:vm';

// Exercise the installed Yoga engine with Fabric's style-update semantics.
// Jest's host views cannot detect a cached vertical flex basis becoming a width.
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const started=Date.now();
// Optional old source / source-directory inputs make it possible to verify that
// this exact reader catches the pre-fix layout, without a second reproduction.
const baselineIndex=process.argv.indexOf('--baseline-dir');
const baseline=baselineIndex>=0?path.resolve(process.argv[baselineIndex+1]):undefined;
const oldStory=process.argv[2]&&!process.argv[2].startsWith('--')?path.resolve(process.argv[2]):undefined;
const sourceFile=file=>ts.createSourceFile(file,readFileSync(file,'utf8'),ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const foundationSource=sourceFile(path.join(root,'src/foundation.ts'));
let foundationObject;
function walk(node,visitor){visitor(node);ts.forEachChild(node,child=>walk(child,visitor));}
walk(foundationSource,node=>{if(ts.isVariableDeclaration(node)&&node.name.getText(foundationSource)==='foundation')foundationObject=node.initializer;});
function property(object,name){
  while(ts.isAsExpression(object)||ts.isParenthesizedExpression(object))object=object.expression;
  assert(ts.isObjectLiteralExpression(object),'Expected an object in the shared layout foundation.');
  return object.properties.find(item=>item.name?.getText(foundationSource)===name)?.initializer;
}
function resolveStyle(expression,source){
  if(ts.isPropertyAccessExpression(expression)){
    const names=expression.getText(source).split('.');
    assert.equal(names.shift(),'foundation','Only the canonical foundation may supply a shared layout reference.');
    return names.reduce(property,foundationObject);
  }
  return expression;
}
const setters={width:'YGNodeStyleSetWidth',minWidth:'YGNodeStyleSetMinWidth',flex:'YGNodeStyleSetFlex',flexGrow:'YGNodeStyleSetFlexGrow',flexShrink:'YGNodeStyleSetFlexShrink',flexBasis:'YGNodeStyleSetFlexBasis'};
function readStyle(file,key,fallback){
  const source=sourceFile(file);let style;
  walk(source,node=>{
    if(ts.isCallExpression(node)&&node.expression.getText(source)==='StyleSheet.create'){
      const properties=node.arguments[0].properties;
      style=properties.find(item=>item.name?.getText(source)===key)?.initializer
        ??properties.find(item=>item.name?.getText(source)===fallback)?.initializer;
    }
  });
  // The old AdaptivePair used an inline horizontal style. Read that actual
  // conditional branch when validating its pre-fix source.
  if(!style&&key==='pairPart')walk(source,node=>{
    if(ts.isFunctionDeclaration(node)&&node.name?.text==='AdaptivePair')walk(node,child=>{
      if(ts.isConditionalExpression(child)&&ts.isObjectLiteralExpression(child.whenFalse)
        &&child.whenFalse.properties.some(item=>item.name?.getText(source)==='flex'))style=child.whenFalse;
    });
  });
  assert(style,`The shared ${key} style must be available to the real-layout regression.`);
  const resolved=resolveStyle(style,source);
  assert(ts.isObjectLiteralExpression(resolved),`Expected an object for ${key}.`);
  return resolved.properties.filter(item=>item.name&&setters[item.name.getText(resolved.getSourceFile())]).map(item=>{
    assert(ts.isPropertyAssignment(item),'Extend the fixture reader for a new shared layout expression.');
    const name=item.name.getText(resolved.getSourceFile()),value=item.initializer;
    if(name==='flexBasis'&&ts.isStringLiteral(value)&&value.text==='auto')return 'YGNodeStyleSetFlexBasisAuto(node);';
    assert(ts.isNumericLiteral(value),`Expected a numeric shared ${key}.${name}.`);
    return `${setters[name]}(node,${value.text});`;
  }).join('\n');
}
const families=[
  {name:'StoryColumns',file:'story-scaffold.tsx',key:'column',gap:32,heights:[216,929]},
  {name:'BenefitScene',file:'plus-scaffold.tsx',key:'pairedPart',gap:24,heights:[176,240]},
  {name:'AdaptivePair',file:'scaffold.tsx',key:'pairPart',gap:16,heights:[44,88]},
  {name:'GuardSummaries',file:'story-scaffold.tsx',key:'summaryPart',fallback:'summary',gap:12,heights:[130,180],alwaysBefore:true},
  {name:'ProtectionHero',file:'story-scaffold.tsx',key:'heroText',fallback:'flex',gap:12,heights:[120,104],hero:true,alwaysBefore:true},
].filter(family=>!oldStory||family.name==='StoryColumns').map(family=>{
  const file=oldStory??path.join(baseline??path.join(root,'review'),family.file);
  return {...family,style:readStyle(file,family.key,family.fallback),stackedStyle:baseline&&family.alwaysBefore?readStyle(file,family.fallback):''};
});
// Evaluate the actual column JSX once, then freeze its props while Yoga resizes
// the native parent. This catches the first frame before a Dimensions event can
// reach JS; an ordinary rerender-at-each-width test cannot exercise that gap.
function storyPresentation(scale){
  const file=oldStory??path.join(baseline??path.join(root,'review'),'story-scaffold.tsx');
  const source=sourceFile(file);let component,styles;
  walk(source,node=>{
    if(ts.isFunctionDeclaration(node)&&node.name?.text==='StoryColumns')component=node;
    if(ts.isCallExpression(node)&&node.expression.getText(source)==='StyleSheet.create')styles=node.arguments[0];
  });
  assert(component&&styles,'StoryColumns and its production styles must be available.');
  const tokens={exports:{}};
  vm.runInNewContext(ts.transpileModule(readFileSync(path.join(root,'src/generated/tokens.ts'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,tokens);
  const values={lavaTokens:tokens.exports.lavaTokens};
  const evaluate=(expression,context)=>vm.runInNewContext(ts.transpileModule(`var value=${expression};value;`,{}).outputText,context);
  const foundation=evaluate(foundationObject.getText(foundationSource),values);
  const context={foundation,space:foundation.space};
  const s=Object.fromEntries(['stack','columns','column'].map(name=>{
    const expression=styles.properties.find(item=>item.name?.getText(source)===name)?.initializer;
    assert(expression,`Missing StoryColumns style: ${name}`);
    return [name,evaluate(expression.getText(source),context)];
  }));
  const jsx={exports:{},foundation,space:foundation.space,s,View:'View',
    useTextScale:()=>scale,useWindowDimensions:()=>({width:852,height:393,scale:3,fontScale:scale}),
    React:{createElement:(type,props,...children)=>({type,props,children})}};
  vm.runInNewContext(ts.transpileModule(component.getText(source),{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.React}}).outputText,jsx);
  const frame=jsx.exports.StoryColumns({primary:'primary',secondary:'secondary'});
  const flatten=style=>Object.assign({},...(Array.isArray(style)?style.flat(Infinity):[style]).filter(Boolean));
  const nativeStyle=style=>Object.entries(flatten(style)).map(([name,value])=>{
    if(setters[name])return `${setters[name]}(node,${value});`;
    if(name==='flexDirection')return `YGNodeStyleSetFlexDirection(node,${{row:'YGFlexDirectionRow',column:'YGFlexDirectionColumn'}[value]});`;
    if(name==='flexWrap')return `YGNodeStyleSetFlexWrap(node,${{wrap:'YGWrapWrap',nowrap:'YGWrapNoWrap'}[value]});`;
    if(name==='alignItems')return `YGNodeStyleSetAlignItems(node,${{'flex-start':'YGAlignFlexStart',stretch:'YGAlignStretch'}[value]});`;
    if(['gap','rowGap','columnGap'].includes(name))return `YGNodeStyleSetGap(node,${{gap:'YGGutterAll',rowGap:'YGGutterRow',columnGap:'YGGutterColumn'}[name]},${value});`;
    assert.fail(`Unsupported column layout property: ${name}`);
  }).join('\n');
  return [frame,...frame.children].map(view=>nativeStyle(view.props.style));
}
const resumeStyles=[1,2].map(storyPresentation);
const yoga=path.join(root,'node_modules/react-native/ReactCommon/yoga');
function cppFiles(directory){return readdirSync(directory,{withFileTypes:true}).flatMap(entry=>entry.isDirectory()?cppFiles(path.join(directory,entry.name)):entry.name.endsWith('.cpp')?[path.join(directory,entry.name)]:[]);}
const directory=mkdtempSync(path.join(tmpdir(),'lava-story-yoga-'));
try{
  const fixture=path.join(directory,'story-columns.cpp');
  writeFileSync(fixture,`
#include <yoga/Yoga.h>
#include <yoga/node/Node.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

int failures=0;
void require(bool condition,const char* message){if(!condition){std::fprintf(stderr,"%s\\n",message);++failures;}}
bool near(float a,float b){return std::abs(a-b)<1.0f;}
// YogaLayoutableShadowNode::updateYogaProps uses setStyle + setDirty. Unlike
// C API property setters, it does not clear the cached computedFlexBasis.
template<class Update> void fabricProps(YGNodeRef node,Update update){
  auto props=YGNodeNew();
  facebook::yoga::resolveRef(props)->setStyle(facebook::yoga::resolveRef(node)->style());update(props);
  facebook::yoga::resolveRef(node)->setStyle(facebook::yoga::resolveRef(props)->style());
  facebook::yoga::resolveRef(node)->setDirty(true);YGNodeFree(props);
}
void clearColumn(YGNodeRef node){
  YGNodeStyleSetFlex(node,YGUndefined);YGNodeStyleSetFlexGrow(node,YGUndefined);
  YGNodeStyleSetFlexShrink(node,YGUndefined);YGNodeStyleSetFlexBasisAuto(node);
  YGNodeStyleSetWidth(node,YGUndefined);YGNodeStyleSetMinWidth(node,YGUndefined);
}
${families.map((family,index)=>`void wideColumn${index}(YGNodeRef node){clearColumn(node);${family.style}}\nvoid stackedColumn${index}(YGNodeRef node){clearColumn(node);${family.stackedStyle}}`).join('\n')}
${resumeStyles.map((styles,index)=>styles.map((style,part)=>`void resumeStyle${index}_${part}(YGNodeRef node){${style}}`).join('\n')).join('\n')}
YGSize measuredContent(YGNodeConstRef node,float width,YGMeasureMode mode,float,YGMeasureMode){
  return {mode==YGMeasureModeUndefined?240:width,*static_cast<float*>(YGNodeGetContext(node))};
}
void calculate(YGNodeRef root){
  // Fabric also dirties ancestors when adopting the updated children.
  facebook::yoga::resolveRef(root)->setDirty(true);
  YGNodeCalculateLayout(root,YGUndefined,YGUndefined,YGDirectionLTR);
}
void scenario(const char* name,void(*wideColumn)(YGNodeRef),void(*stackedColumn)(YGNodeRef),float gap,float primaryHeight,float secondaryHeight,bool reverse=false,bool hero=false){
  auto root=YGNodeNew(),primary=YGNodeNew(),secondary=YGNodeNew();
  auto primaryContent=YGNodeNew(),secondaryContent=YGNodeNew(),row=YGNodeNew();
  auto glyph=YGNodeNew(),label=YGNodeNew(),accessory=YGNodeNew();
  YGNodeInsertChild(root,primary,0);YGNodeInsertChild(root,secondary,1);
  YGNodeInsertChild(primary,primaryContent,0);YGNodeInsertChild(secondary,secondaryContent,0);
  YGNodeInsertChild(secondaryContent,row,0);YGNodeInsertChild(row,glyph,0);
  YGNodeInsertChild(row,label,1);YGNodeInsertChild(row,accessory,2);
  YGNodeSetContext(primaryContent,&primaryHeight);YGNodeSetMeasureFunc(primaryContent,measuredContent);
  YGNodeStyleSetHeight(secondaryContent,secondaryHeight);
  if(hero)YGNodeStyleSetWidth(secondary,96);
  YGNodeStyleSetFlexDirection(row,YGFlexDirectionRow);YGNodeStyleSetAlignItems(row,YGAlignCenter);
  YGNodeStyleSetMinHeight(row,54);YGNodeStyleSetPadding(row,YGEdgeHorizontal,16);YGNodeStyleSetGap(row,YGGutterAll,12);
  YGNodeStyleSetWidth(glyph,24);YGNodeStyleSetHeight(glyph,24);
  YGNodeStyleSetFlex(label,1);YGNodeStyleSetHeight(label,20);
  YGNodeStyleSetWidth(accessory,44);YGNodeStyleSetHeight(accessory,12);
  // Two rotations exercise a previously laid-out phone column and an iPad
  // width, preserving the same children and their different content heights.
  for(float width:hero?std::initializer_list<float>{357.0f,548.0f}:std::initializer_list<float>{698.0f,988.0f}){
    fabricProps(root,[hero](auto node){YGNodeStyleSetFlexDirection(node,hero?YGFlexDirectionColumnReverse:YGFlexDirectionColumn);YGNodeStyleSetAlignItems(node,hero?YGAlignFlexStart:YGAlignStretch);YGNodeStyleSetWidth(node,357);YGNodeStyleSetGap(node,YGGutterAll,16);});
    fabricProps(primary,stackedColumn);if(!hero)fabricProps(secondary,stackedColumn);
    calculate(root);
    require(near(YGNodeLayoutGetHeight(primary),primaryHeight),"Portrait primary content changed height.");
    require(near(YGNodeLayoutGetHeight(secondary),secondaryHeight),"Portrait secondary content changed height.");
    fabricProps(root,[width,gap,reverse](auto node){YGNodeStyleSetFlexDirection(node,reverse?YGFlexDirectionRowReverse:YGFlexDirectionRow);YGNodeStyleSetAlignItems(node,YGAlignFlexStart);YGNodeStyleSetWidth(node,width);YGNodeStyleSetGap(node,YGGutterAll,gap);});
    fabricProps(primary,wideColumn);if(!hero)fabricProps(secondary,wideColumn);
    calculate(root);
    float expected=hero?width-gap-96:(width-gap)/2,primaryWidth=YGNodeLayoutGetWidth(primary),secondaryWidth=YGNodeLayoutGetWidth(secondary);
    std::printf("%s content %.0f/%.0f; available %.0f: parts %.2f/%.2f, expected %.2f/%.2f\\n",name,primaryHeight,secondaryHeight,width,primaryWidth,secondaryWidth,expected,hero?96:expected);
    require(near(primaryWidth,expected)&&near(secondaryWidth,hero?96:expected),"Rotation reused a previous height as a column width.");
    require(near(YGNodeLayoutGetWidth(row),secondaryWidth),"Utility row escaped its column.");
    require(near(YGNodeLayoutGetWidth(accessory),44),"Utility accessory must retain its 44pt slot.");
    require(hero||YGNodeLayoutGetLeft(accessory)+YGNodeLayoutGetWidth(accessory)<=secondaryWidth,"Utility accessory escaped its column.");
    require(YGNodeLayoutGetLeft(secondary)+secondaryWidth<=width+1,"Secondary column escaped its viewport.");
    require(near(YGNodeLayoutGetHeight(primary),primaryHeight)&&near(YGNodeLayoutGetHeight(secondary),secondaryHeight),"Rotation discarded existing content height.");
  }
  YGNodeFreeRecursive(root);
}
void resumeScenario(int scale,void(*rootStyle)(YGNodeRef),void(*primaryStyle)(YGNodeRef),void(*secondaryStyle)(YGNodeRef)){
  auto root=YGNodeNew(),primary=YGNodeNew(),secondary=YGNodeNew();
  auto primaryContent=YGNodeNew(),secondaryContent=YGNodeNew();
  YGNodeInsertChild(root,primary,0);YGNodeInsertChild(root,secondary,1);
  YGNodeInsertChild(primary,primaryContent,0);YGNodeInsertChild(secondary,secondaryContent,0);
  rootStyle(root);primaryStyle(primary);secondaryStyle(secondary);
  // Production lanes are containers: measured descendants supply their height
  // through the wrapper's layout/cache path, not a definite wrapper height.
  float primaryHeight=216,secondaryHeight=929;
  YGNodeSetContext(primaryContent,&primaryHeight);YGNodeSetContext(secondaryContent,&secondaryHeight);
  YGNodeSetMeasureFunc(primaryContent,measuredContent);YGNodeSetMeasureFunc(secondaryContent,measuredContent);
  for(float width:{698.f,361.f,988.f,288.f,698.f,361.f}){
    // Only native geometry changes; both child identities and all JS styles stay frozen.
    fabricProps(root,[width](auto node){YGNodeStyleSetWidth(node,width);});calculate(root);
    float a=YGNodeLayoutGetWidth(primary),b=YGNodeLayoutGetWidth(secondary);
    float x=YGNodeLayoutGetLeft(secondary),y=YGNodeLayoutGetTop(secondary);
    bool paired=scale==1&&width>=698;
    std::printf("StoryColumns frozen JS at text scale %d, native width %.0f: parts %.0f/%.0f, second at %.0f/%.0f\\n",scale,width,a,b,x,y);
    require(paired?(near(a,(width-32)/2)&&near(a,b)&&near(x,a+32)&&near(y,0))
                  :(near(a,width)&&near(b,width)&&near(x,0)&&near(y,232)),
            "First native resize frame must fit columns before JS receives new dimensions.");
    require(near(YGNodeLayoutGetHeight(primary),216)&&near(YGNodeLayoutGetHeight(secondary),929),
            "Geometry-only reflow must retain existing content height.");
  }
  YGNodeFreeRecursive(root);
}
int main(){
  ${families.flatMap((family,index)=>[family.heights,[family.heights[0]*(family.hero?3:2),family.heights[1]]].map(heights=>`scenario("${family.name}",wideColumn${index},stackedColumn${index},${family.gap},${heights[0]},${heights[1]},${!!family.reverse},${!!family.hero});`)).join('\n')}
  ${resumeStyles.map((_,index)=>`resumeScenario(${index?2:1},resumeStyle${index}_0,resumeStyle${index}_1,resumeStyle${index}_2);`).join('\n')}
  return failures?1:0;
}
`);
  const binary=path.join(directory,'story-columns');
  execFileSync(process.env.CXX??'c++',['-std=c++20','-O0',`-I${yoga}`,fixture,...cppFiles(path.join(yoga,'yoga')),'-o',binary],{stdio:'inherit'});
  execFileSync(binary,[],{stdio:'inherit'});
  console.log(`Real-Yoga responsive scaffold transitions passed in ${((Date.now()-started)/1000).toFixed(1)}s.`);
}finally{rmSync(directory,{recursive:true,force:true});}
