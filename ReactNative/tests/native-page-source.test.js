const {existsSync,readFileSync,readdirSync}=require('node:fs');
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

test('only React modules register runtime ownership while native snapshot observers remain callback-only',()=>{
  // The ObjC++ module and native host share Swift observation, but only module
  // teardown participates in the executable last-runtime/unclaimed-owner policy.
  const bridge=read('native-app/LavaAppBridge.swift'),module=read('native-app/LavaAppModule.mm'),host=read('native-app/LavaAppHost.swift');
  const observer=bridge.indexOf('@objc func observe('),runtime=bridge.indexOf('@objc func registerRuntime('),remove=bridge.indexOf('@objc func removeObserver(');
  expect(observer).toBeGreaterThanOrEqual(0);expect(runtime).toBeGreaterThan(observer);expect(remove).toBeGreaterThan(runtime);
  expect(bridge.slice(observer,runtime)).not.toContain('runtimeOwnership.register(');
  expect(bridge.slice(runtime,remove)).toContain('runtimeOwnership.register(');
  expect(bridge.slice(runtime,remove)).not.toContain('observe(');
  const moduleObserver=module.slice(module.indexOf('- (void)ensureObserver {'),module.indexOf('- (void)invalidate {'));
  expect(moduleObserver).toContain('observe:^(NSString *snapshot)');
  expect(moduleObserver).not.toContain('observeRuntime');
  expect(host).toContain('onboardingChromeObserver = LavaAppBridge.shared.observe {');
  expect(host).not.toContain('observeRuntime');
  const teardown=module.slice(module.indexOf('- (void)invalidate {'));
  expect(teardown).toMatch(/_invalidated = YES;[\s\S]*removeObserver:_observerToken[\s\S]*retireRuntime:_runtimeToken/);
  expect(module).toContain('command:request runtimeID:self->_runtimeToken');
});

test('module runtime admission precedes its first asynchronous read or command',()=>{
  const module=read('native-app/LavaAppModule.mm');
  // Native initial properties can create an authentication owner before the
  // first JS read. RN finishes RCTInitializing before invalidation, whereas
  // codegen discovery constructs an instance without that runtime setup hook.
  const initializer=module.match(/- \(void\)initialize \{([\s\S]*?)\n\}/);
  expect(initializer).not.toBeNull();
  expect(module).toContain('#import <React/RCTInitializing.h>');
  expect(module).toContain('@interface LavaAppModule () <RCTInitializing>');
  expect(module).not.toMatch(/- \(instancetype\)init\b/);
  expect(initializer[1]).toMatch(/#ifdef LAVA_REACT_NATIVE[\s\S]*_runtimeToken = \[\[LavaAppBridge shared\] registerRuntime\];[\s\S]*#endif/);
  // JSI installs the generated callback on its requesting thread after native
  // initialization returns. Observing here would race that std::function write.
  expect(initializer[1]).not.toContain('ensureObserver');
  expect(initializer[1]).not.toContain('dispatch_async');
  expect(module).toContain('+ (BOOL)requiresMainQueueSetup { return YES; }');
  const registration=module.slice(module.indexOf('- (void)ensureObserver {'),module.indexOf('- (void)invalidate {'));
  expect(registration).toContain('if (_observerToken || _invalidated) return;');
  for(const signature of ['- (void)getSnapshot:', '- (void)command:']){
    const method=module.slice(module.indexOf(signature),module.indexOf('\n}',module.indexOf(signature)));
    expect(method).toContain('[self ensureObserver];');
  }
});

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

test('migrated settings compose shared RN screens inside their enclosing native navigation',()=>{
  const routes=read('review/LavaUIReview.tsx');
  const pages=read('review/NativePageScreen.tsx');
  const qa=read('review/QAFlowAdapter.ios.tsx');
  // Live import, passcode and feedback use native-owned flow visits. Ordinary
  // settings routes keep the enclosing native bar and render RN compositions.
  expect(routes).toContain("!['Import','Passcode','Feedback'].includes(name)");
  expect(routes).toContain("['AutoSwitch','DNSPatch'].includes(name)?{headerLargeTitleEnabled:false}:{}");
  expect(routes).not.toContain("name==='DeviceQA'?{headerShown:false}");
  expect(pages).toContain('return <AutoSwitchPage/>');
  expect(pages).toContain('return <DNSHelpScreen');
  expect(pages).toContain("const navigation=useReviewNavigation(route.params)");
  expect(pages).toContain("openDNS:()=>navigation.navigate('DNS'),openVPN:()=>navigation.navigate('VPNChaining')");
  expect(pages).toContain('return <QAFlowAdapter id={id}/>');
  expect(qa).toContain("useToolbar({title:'Device QA'");
  expect(qa).toContain('<QAScreen state={presentation} port={rootPort}/>');
  // Only the QA detail sheet needs its own independent native navigator.
  expect(qa).toContain('<NavigationIndependentTree>');
  expect(qa).toContain('screenOptions={{...nativeInlineHeader,...push}}');
  for(const path of ['native-app/LavaNativePageContent.swift','ios/LavaSecUIReview/LavaNativePageView.mm','specs/LavaNativePageNativeComponent.ts']){
    expect(existsSync(join(__dirname,'..',path))).toBe(false);
  }
});

test('RN settings destinations and contextual returns share authentication and visit lifetime gates',()=>{
  const navigation=read('review/navigation.ts');
  const vpn=read('review/VPNChainingScreen.tsx');
  expect(navigation).toContain("['Components','Explore','Settings','Account','Upgrade','Customization','Guardian','DNS','DNSPatch','VPNChaining','AutoSwitch','Privacy','DeviceQA'].includes(name) ? 'appSettings'");
  expect(navigation).toContain("app.command({type: 'navigation.authorize', surface})");
  expect(navigation).toContain('if(!active.current||started!==epoch.current||!mayInteractWithPresentation(app))return;');
  expect(navigation).toContain('authorizeThen(name,()=>navigation.navigate(...args))');
  expect(navigation).toContain('previous.key!==context?.returnKey');
  expect(navigation).toContain('current.routes[current.index]?.key===origin?.key&&current.routes[current.index-1]?.key===previous.key');
  expect(vpn).toContain('const nav=useReviewNavigation(route.params)');
  expect(vpn).toContain("previous?.name==='DNS'&&previous.key===route.params.returnKey)nav.goBack();else nav.navigate('DNS')");
});

test('pushed iOS DNS injects the ordinary direct scroll owner without changing shared or default page metrics',()=>{
  const source=parse('review/NativePageScreen.tsx');
  const page=descendants(source,node=>ts.isFunctionDeclaration(node)&&node.name?.text==='DNSHelpPage')[0];
  const root=descendants(page,ts.isReturnStatement).find(node=>node.expression&&ts.isJsxElement(node.expression)).expression;
  expect(root.openingElement.tagName.getText(source)).toBe('Screen');
  const content=root.openingElement.attributes.properties.find(node=>node.name?.text==='contentContainerStyle').initializer.expression;
  expect(Object.fromEntries(content.properties.map(node=>[node.name.getText(source),node.initializer.getText(source)]))).toEqual({paddingTop:'28',paddingBottom:'44'});
  expect(read('review/NativePageScreen.tsx')).toContain('page={DNSHelpPage}');
  expect(read('src/flows/dns-help/DNSHelpScreen.tsx')).toContain('page:Page=FlowSheet');

  const primitives=parse('review/primitives.tsx');
  const screen=descendants(primitives,node=>ts.isFunctionDeclaration(node)&&node.name?.text==='Screen')[0];
  const scroll=descendants(screen,ts.isReturnStatement).find(node=>node.expression&&ts.isJsxElement(node.expression)).expression;
  expect(scroll.openingElement.tagName.getText(primitives)).toBe('ScrollView');
  const styles=scroll.openingElement.attributes.properties.find(node=>node.name?.text==='contentContainerStyle').initializer.expression.elements;
  expect(styles[0].getText(primitives)).toBe('styles.content');
  expect(styles[1].getText(primitives)).toContain('paddingTop:pageTopPadding(layout)');
  expect(styles[1].getText(primitives)).toContain('paddingBottom:foundation.space.screenBottom*layout.scale');
  expect(styles.slice(-2).map(node=>node.getText(primitives))).toEqual(['contentContainerStyle','horizontalContentInsets']);
});

test('RN VPN composition leaves configuration authority and credentials in the native command owner',()=>{
  const source=parse('review/VPNChainingScreen.tsx');
  const page=descendants(source,node=>ts.isFunctionDeclaration(node)&&node.name?.text==='VPNChainingScreen')[0];
  const returns=descendants(page,ts.isReturnStatement);
  const root=returns.find(node=>node.expression&&ts.isJsxElement(node.expression));
  expect(root.expression.openingElement.tagName.getText(source)).toBe('Screen');
  const vpn=read('review/VPNChainingScreen.tsx');
  expect(vpn).toContain('const admission=useVPNPageAdmission()');
  expect(vpn).toContain("{type:'vpn.begin',id,generation:vpn?.generation??''}");
  expect(vpn).toContain("{type:'vpn.edit',id,index}");
  expect(vpn).toContain("{type:'vpn.commit',id:draftRef.current.id}");
  expect(vpn).toContain("{type:'vpn.cancel',id}");
  const native=read('native-app/LavaAppSettings.swift');
  const commands=native.slice(native.indexOf('func vpnCommand('),native.indexOf('func dnsChoice('));
  expect(native).toContain('guard canReadPresentation(.appSettings) else { return ["authorized": false] }');
  expect(commands).toContain('try await authorize(.appSettings, "Open VPN chaining settings")');
  const authorization=commands.indexOf('try await authorize(.appSettings, "Edit VPN chaining")');
  const foreground=commands.indexOf('guard UIApplication.shared.applicationState == .active');
  const visit=commands.indexOf('guard var draft = wireGuardDraft, draft.id == input["id"] as? String');
  expect(authorization).toBeGreaterThan(0);
  expect(foreground).toBeGreaterThan(authorization);
  expect(visit).toBeGreaterThan(foreground);
  expect(commands).toContain('(input["generation"] as? String ?? "") == (status.storedConfigurationGeneration.map(String.init) ?? "")');
  expect(commands).toContain('current.id == sessionID, current.revision == editorRevision');
  expect(commands).toContain('name: "vpnConfiguration"');
  expect(existsSync(join(__dirname,'..','../LavaSecApp/VPNChainingSettingsView.swift'))).toBe(false);
});

test('RN QA callbacks and post-authentication native actions retain exact root and detail visits',()=>{
  const adapter=read('review/QAFlowAdapter.ios.tsx');
  expect(adapter).toContain('live?.qa?.id===id?live.qa:undefined');
  expect(adapter).toContain('current?.id!==id||current.detail?.id!==detail?.id');
  expect(adapter).toContain("{type:'qa.command',id,...(detail?{detail:detail.id}:{}),...action}");
  expect(adapter).toContain("{type:'qa.command',id,action:'leave'}");
  const native=read('native-app/LavaAppQA.swift');
  const commands=native.slice(native.indexOf('func qaCommand('),native.indexOf('func presentQAMockOnboarding('));
  const authorization=commands.indexOf('try await authorize(surface,');
  const revalidation=commands.indexOf('qaSession === ownerBeforeAuthentication');
  const mutation=commands.indexOf('await owner.command(action, input)');
  expect(authorization).toBeGreaterThan(0);
  expect(revalidation).toBeGreaterThan(authorization);
  expect(mutation).toBeGreaterThan(revalidation);
  expect(commands).toContain('LavaQAVisitAdmissions.lifetime.admit(id: id, ticket: ticket)');
  expect(commands).toContain('guard owner.admits(action, input: input)');
  expect(native).toContain('input["detail"] as? String == detailID.uuidString');
});

test('shared flow modules keep platform navigation and native specs behind typed adapter ports',()=>{
  const files=[];
  const collect=path=>{
    for(const entry of readdirSync(join(__dirname,'..',path),{withFileTypes:true})){
      const child=`${path}/${entry.name}`;
      if(entry.isDirectory())collect(child);
      else if(/\.tsx?$/.test(child)&&!/\.ios\.tsx?$/.test(child))files.push(child);
    }
  };
  collect('src/flows');
  expect(files.length).toBeGreaterThanOrEqual(15);
  for(const path of files){
    const source=parse(path);
    const dependencies=descendants(source,node=>ts.isImportDeclaration(node)||ts.isExportDeclaration(node))
      .map(node=>node.moduleSpecifier?.text).filter(Boolean);
    // Platform UI is reached through ./ui; feature screens cannot reach a
    // review context, native spec, or navigation implementation directly.
    expect({path,violations:dependencies.filter(name=>/\.ios$|(?:^|\/)(?:review|specs|native-app)(?:\/|$)|^@react-navigation\//.test(name))})
      .toEqual({path,violations:[]});
    const authority=descendants(source,node=>ts.isIdentifier(node)&&['useReview','NativeModules','TurboModuleRegistry','Platform'].includes(node.text));
    expect({path,authority:authority.map(node=>node.text)}).toEqual({path,authority:[]});
  }
  for(const [path,name] of [
    ['preparation/PreparationScreen.tsx','PreparationScreen'],['import/ImportFlow.tsx','ImportFlow'],
    ['account-backup/AccountBackupFlow.tsx','AccountBackupFlow'],['passcode/PasscodeScreen.tsx','PasscodeScreen'],
    ['qa/QAScreens.tsx','QAScreen'],['qa/QAScreens.tsx','QADetailScreen'],['dns-help/DNSHelpScreen.tsx','DNSHelpScreen'],
  ]){
    const source=parse(`src/flows/${path}`);
    const screen=descendants(source,node=>ts.isFunctionDeclaration(node)&&node.name?.text===name)[0];
    expect(screen?.parameters[0]?.type).toBeDefined();
  }
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
