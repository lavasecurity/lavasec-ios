// Pins the guard's template-literal handling. A realized value that only exists as a
// template (`Notes mode ${on?'on':'off'}` in review/SudokuScreen.tsx) must still be
// treated as production copy, while runtime-composed data values must not be.
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const teardown=require('./i18n-coverage/global-teardown');

async function runGuard(value){
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'lava-i18n-guard-'));
  const file=path.join(directory,'misses.jsonl');
  fs.writeFileSync(file,JSON.stringify(value)+'\n');
  const previous=process.env.LAVA_I18N_MISSES;
  process.env.LAVA_I18N_MISSES=file;
  try{await teardown();return null;}catch(error){return error.message;}
  finally{process.env.LAVA_I18N_MISSES=previous;}
}
test('realized template copy counts as production source',async()=>{
  await expect(runGuard('Notes mode on')).resolves.toContain('Notes mode on');
  await expect(runGuard('Puzzle assistance off')).resolves.toContain('Puzzle assistance off');
});
test('runtime-composed data does not count as production source',async()=>{
  await expect(runGuard('0 rules')).resolves.toBeNull();
  await expect(runGuard('Pause for 5 minutes')).resolves.toBeNull();
  await expect(runGuard('iOS 26.5')).resolves.toBeNull();
});
