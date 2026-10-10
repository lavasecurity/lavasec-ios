const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const ts=require('typescript');
const read=path=>readFileSync(join(__dirname,'..',path),'utf8');
const parse=path=>ts.createSourceFile(path,read(path),ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const descendants=(node,predicate)=>{
  const matches=[];
  const visit=child=>{if(predicate(child))matches.push(child);ts.forEachChild(child,visit);};
  visit(node);return matches;
};
const titleProperties=source=>descendants(source,node=>ts.isPropertyAssignment(node)&&node.name.getText()==='headerLargeTitleEnabled');

test('native navigation colors consume resolved app appearance while outer presentation owns system fallback',()=>{
  const source=parse('review/LavaUIReview.tsx');
  const root=descendants(source,node=>ts.isFunctionDeclaration(node)&&node.name?.text==='RootStack')[0];
  const scheme=descendants(root,node=>ts.isVariableDeclaration(node)&&node.name.getText(source)==='scheme')[0];
  expect(scheme.initializer.getText(source)).toBe('useLavaColorScheme()');
  expect(descendants(root,node=>ts.isCallExpression(node)&&node.expression.getText(source)==='useColorScheme')).toHaveLength(0);
  const presentation=descendants(source,node=>ts.isFunctionDeclaration(node)&&node.name?.text==='LavaPresentation')[0];
  expect(descendants(presentation,node=>ts.isCallExpression(node)&&node.expression.getText(source)==='useColorScheme')).toHaveLength(1);
});

test('native title options use the supported dependency contract, including inline overrides',()=>{
  // native-stack 7.18.10 accepts the old alias when painting a title, but its
  // animated header-height debounce reads only headerLargeTitleEnabled. Mixing
  // names also lets an inherited true value defeat an inline/sheet false alias.
  // This is a JS/native dependency boundary pin; rendered transitions are tested
  // separately by the native Guard/Filters navigation journey.
  for(const path of ['review/LavaUIReview.tsx','review/scaffold.tsx']){
    const source=parse(path);
    const deprecated=descendants(source,node=>ts.isPropertyAssignment(node)&&node.name.getText(source)==='headerLargeTitle');
    expect(deprecated.map(node=>node.getText(source))).toEqual([]);
  }
  const source=parse('review/LavaUIReview.tsx');
  const screenOptions=descendants(source,node=>ts.isJsxAttribute(node)&&node.name.getText(source)==='screenOptions');
  const rootOptions=screenOptions.find(node=>titleProperties(node).length);
  expect(rootOptions).toBeDefined();
  expect(titleProperties(rootOptions).map(node=>node.initializer.getText(source))).toEqual(['true']);

  const routeOption=titleProperties(source).find(node=>ts.isPrefixUnaryExpression(node.initializer));
  expect(routeOption).toBeDefined();
  const excluded=descendants(routeOption,node=>ts.isArrayLiteralExpression(node))[0];
  expect(excluded.elements.map(node=>node.text)).toEqual([
    'Filter','Guardian','Review','Import','ShareDetail','Passcode','AddDomain','AddBlocklist',
  ]);
  expect(routeOption.initializer.getText(source)).toMatch(/\.includes\(name\)$/);
  for(const route of ['Passcode','AutoSwitch','DNSPatch']){
    const override=descendants(source,node=>ts.isConditionalExpression(node)&&(node.condition.getText(source)===`name==='${route}'` || (node.condition.getText(source).endsWith('.includes(name)') && descendants(node.condition,ts.isStringLiteral).some(value=>value.text===route))))[0];
    expect(override).toBeDefined();
    expect(titleProperties(override.whenTrue).map(node=>node.initializer.getText(source))).toEqual(['false']);
  }
  const scaffold=parse('review/scaffold.tsx');
  const fullSheet=descendants(scaffold,node=>ts.isVariableDeclaration(node)&&node.name.getText(scaffold)==='fullSheetPresentation')[0];
  expect(titleProperties(fullSheet).map(node=>node.initializer.getText(scaffold))).toEqual(['false']);
  expect(descendants(fullSheet,ts.isSpreadAssignment).map(node=>node.expression.getText(scaffold))).toContain('nativeInlineHeader');
  const inlineHeader=descendants(scaffold,node=>ts.isVariableDeclaration(node)&&node.name.getText(scaffold)==='nativeInlineHeader')[0];
  expect(titleProperties(inlineHeader).map(node=>node.initializer.getText(scaffold))).toEqual(['false']);
  // Sudoku inherits the supported key from the shared full-screen modal
  // scaffold instead of the alias, exactly as sheet routes inherit the sheet
  // scaffold constant above. Pin the route/constant wiring itself so the
  // route-level guarantee survives a dropped spread.
  const fullScreenModal=descendants(scaffold,node=>ts.isVariableDeclaration(node)&&node.name.getText(scaffold)==='fullScreenModalPresentation')[0];
  expect(titleProperties(fullScreenModal).map(node=>node.initializer.getText(scaffold))).toEqual(['false']);
  const sudokuRoute=descendants(source,node=>ts.isConditionalExpression(node)&&node.condition.getText(source)==="name==='Sudoku'")[0];
  expect(sudokuRoute).toBeDefined();
  expect(descendants(sudokuRoute.whenTrue,ts.isSpreadAssignment).map(node=>node.expression.getText(source))).toEqual(['fullScreenModalPresentation']);
  const sudokuTitle=descendants(sudokuRoute.whenTrue,node=>ts.isPropertyAssignment(node)&&node.name.getText(source)==='title')[0];
  expect(sudokuTitle.initializer.getText(source)).toBe("''");
});

test('embedded native settings retain one enclosing navigation bar and visit-scoped destination bridge',()=>{
  const native=read('native-app/LavaNativePageContent.swift');
  const routes=read('review/LavaUIReview.tsx');
  const event=read('ios/LavaSecUIReview/LavaNativePageView.mm');
  const spec=read('specs/LavaNativePageNativeComponent.ts');
  // Device QA retains its bounded native toolbar. Live feedback is the shared flow.
  expect(routes).toContain("!['Import','Passcode','Feedback'].includes(name)");
  expect(native).toContain('NavigationStack {\n                PhoneQASettingsView()');
  expect(routes).toContain("['AutoSwitch','DNSPatch'].includes(name)?{headerLargeTitleEnabled:false}:{}");
  expect(routes).toContain("name==='DeviceQA'?{headerShown:false}");
  expect(routes).not.toContain("['VPNChaining','DeviceQA'].includes(name)||name==='Feedback'&&app?{headerShown:false}");
  expect(native).toContain('self.visit == currentVisit, self.interactionAllowed');
  expect(native).toContain('onOpenDNSSettings: { onNavigate("DNS") }');
  expect(native).toContain('onOpenUpgrade: { onNavigate("Upgrade") }');
  expect(native).toContain('onPresentConfigurationEditor: { index, generation, name, exists, saveDraft, reportRemovalFailure in');
  expect(native).toContain('name: "vpnConfiguration"');
  expect(event).toContain('page.onNavigate =');expect(event).toContain('->onNavigate(');
  expect(spec).toContain('onNavigate?: CodegenTypes.DirectEventHandler');
});

test('standalone VPN navigation remains available while embedded content attaches no orphan destinations',()=>{
  const native=read('../LavaSecApp/VPNChainingSettingsView.swift');
  expect(native).toContain('ownsUpgrade: onOpenUpgrade == nil, ownsDNS: onOpenDNSSettings == nil');
  expect(native).toContain('if ownsUpgrade {');expect(native).toContain('if ownsDNS {');
  expect(native).toContain('.sheet(isPresented: $showConfigurationEditor)');
  expect(native).toContain('security.requireAuthentication(for: .appSettings, reason: "Edit DNS settings")');
});

test('production navigation registers VPN chaining while keeping test destinations behind QA',()=>{
  const source=parse('review/LavaUIReview.tsx');
  const filter=descendants(source,node=>ts.isCallExpression(node)&&node.expression.getText(source)==='routeDestinations.filter')[0];
  expect(filter).toBeDefined();
  const callback=filter.arguments[0];
  const expression=callback.body.getText(source);
  const allows=Function('name','app','qaTools',`return (${expression});`);
  for(const qa of [false,true]){
    expect(allows('VPNChaining',{}, {current:qa})).toBe(true);
    expect(allows('DeviceQA',{}, {current:qa})).toBe(qa);
    expect(allows('Components',{}, {current:qa})).toBe(qa);
  }
  expect(allows('VPNChaining',undefined,{current:true})).toBe(false);
});

test('read-only foreground reentry renews App Unlock without weakening editing or exact native visit fences',()=>{
  // These Swift authorization calls cannot execute in Jest. Pin the native
  // bridge boundary, including the checks after suspended authentication.
  const source=read('native-app/LavaAppFlows.swift');
  const command=source.slice(source.indexOf('func foregroundFlowCommand('),source.indexOf('func customEntryProjection('));
  const entry=command.match(/if action == "foreground\.enter", (\[[^\]]+\])\.contains\(flow\.name\) \{\s*try await authorize\(\.appUnlock, "Unlock Lava"\)\s*\} else \{\s*try await authorize\(\.filterEditing, "Manage filters"\)\s*\}/);
  expect(entry).not.toBeNull();
  const names=JSON.parse(entry[1]);
  expect(names).toEqual(['automation','licenses']);
  const requiredSurface=(action,name)=>action==='foreground.enter'&&names.includes(name)?'appUnlock':'filterEditing';
  for(const name of ['automation','licenses'])expect(requiredSurface('foreground.enter',name)).toBe('appUnlock');
  for(const name of ['createFilter','renameFilter','deleteFilters','feedback','vpnConfiguration'])expect(requiredSurface('foreground.enter',name)).toBe('filterEditing');
  for(const name of names)expect(requiredSurface('foreground.submit',name)).toBe('filterEditing');
  const currentID=command.indexOf('guard let flow, flow.usesReactPresentation, input["id"] as? String == flow.id.uuidString');
  const postAuthorization=command.indexOf('guard UIApplication.shared.applicationState == .active, self.flow?.id == flow.id');
  const acceptedEntry=command.indexOf('if action == "foreground.enter" { return NSNull() }');
  expect(currentID).toBeGreaterThanOrEqual(0);
  expect(currentID).toBeLessThan(entry.index);
  expect(postAuthorization).toBeGreaterThan(entry.index+entry[0].length);
  expect(postAuthorization).toBeLessThan(acceptedEntry);
  // The projection itself requires only App Unlock for the two read-only kinds.
  const projection=source.slice(source.indexOf('func foregroundFlowProjection('),source.indexOf('func foregroundFlowCommand('));
  expect(projection).toContain('guard canReadPresentation(.appUnlock) else { return nil }');
  expect(projection).toContain('if ["createFilter", "renameFilter", "deleteFilters"].contains(flow.name), !canReadPresentation(.filterEditing) { return nil }');
});
