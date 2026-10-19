import {readFileSync,existsSync,readdirSync} from 'node:fs';
import {dirname,join,resolve} from 'node:path';
import ts from 'typescript';

const root=resolve(__dirname,'../src');
function visitModule(file,seen=new Set()){
  if(seen.has(file))return seen;
  seen.add(file);
  expect(file).not.toMatch(/\.ios\.|\/specs\/|\/generated\//);
  const ast=ts.createSourceFile(file,readFileSync(file,'utf8'),ts.ScriptTarget.Latest,true);
  for(const statement of ast.statements){
    const specifier=(ts.isImportDeclaration(statement)||ts.isExportDeclaration(statement))&&statement.moduleSpecifier;
    if(!specifier||!ts.isStringLiteral(specifier))continue;
    const name=specifier.text;
    if(!name.startsWith('.')){
      expect(['react','react-native']).toContain(name);
      if(name==='react-native')expect(statement.importClause?.isTypeOnly).toBe(true);
      continue;
    }
    const stem=resolve(dirname(file),name);
    const target=[`${stem}.ts`,`${stem}.tsx`,join(stem,'index.ts')].find(existsSync);
    expect(target).toBeDefined();
    visitModule(target,seen);
  }
  return seen;
}

test('public contracts and shared behavior resolve without iOS modules, generated tokens or bridge specs',()=>{
  const files=visitModule(join(root,'ui/contracts/index.ts'));
  visitModule(join(root,'ui/behavior/index.ts'),files);
  expect(files.has(join(root,'feedback.tsx'))).toBe(true);
  for(const name of readdirSync(join(root,'ui/contracts')).filter(name=>name.endsWith('.ts')))
    expect(files.has(join(root,'ui/contracts',name))).toBe(true);
});
