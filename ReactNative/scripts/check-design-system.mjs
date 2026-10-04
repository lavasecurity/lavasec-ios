import {readFileSync,readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';

const root=new URL('../review/',import.meta.url);
const compositions=new Set(['primitives.tsx','scaffold.tsx','story-scaffold.tsx','detail-scaffold.tsx','activity-scaffold.tsx','sudoku-scaffold.tsx','plus-scaffold.tsx','paging-scaffold.tsx','settings-scaffold.tsx','LavaUIReview.tsx']);
// Shared authoritative state-to-material renderer; owns endpoint geometry and interrupted motion.
compositions.add('guard-material.tsx');
// Shared iOS/Android recipient-image composition. Its fixed export pixel geometry
// is independent of interactive screen/control typography and sender text scale.
compositions.add('FilterShareCard.tsx');
// One opaque lifecycle composition serves the root and separate UIKit routes.
compositions.add('PresentationCover.tsx');
// Screens arrange shared pieces and own state. Paint, typography and control
// geometry belong to the foundation/composition layer. Data geometry belongs to
// its chart/game renderer rather than a second copy of a standard control.
export function inspectScreen(source,name){
  const ast=ts.createSourceFile(name,source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
  const violations=[];
  const report=(node,rule)=>violations.push({file:name,line:ast.getLineAndCharacterOfPosition(node.getStart(ast)).line+1,rule});
  const visit=node=>{
    if(ts.isJsxAttribute(node)&&node.name.getText(ast)==='size'){
      const tag=node.parent.parent.tagName?.getText(ast);
      if(tag==='Copy')report(node,'Use a semantic Copy role; text sizes belong to the scaffold.');
    }
    if(ts.isPropertyAssignment(node)&&['fontSize','fontFamily','fontWeight','lineHeight','borderRadius','borderWidth','backgroundColor','borderColor'].includes(node.name.getText(ast))){
      report(node,'Move visual styling into a shared scaffold composition.');
    }
    if(ts.isCallExpression(node)&&node.expression.getText(ast)==='StyleSheet.create')report(node,'Screen-local style sheets must become shared compositions.');
    ts.forEachChild(node,visit);
  };
  visit(ast);return violations;
}

export function inspectDesignModule(source,name){
  return compositions.has(name)?[]:inspectScreen(source,name);
}

if(process.argv[1]===fileURLToPath(import.meta.url)){
  const files=readdirSync(root).filter(name=>name.endsWith('.tsx')&&!compositions.has(name));
  const violations=files.flatMap(name=>inspectDesignModule(readFileSync(new URL(name,root),'utf8'),name));
  if(violations.length){for(const violation of violations)console.error(`${violation.file}:${violation.line}: ${violation.rule}`);process.exitCode=1;}
  else console.log(`Design scaffold boundaries verified across ${files.length} screen modules.`);
}
