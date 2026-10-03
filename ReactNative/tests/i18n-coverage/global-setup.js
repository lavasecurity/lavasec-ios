// One miss log per Jest run; workers inherit the path through the environment.
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
module.exports=async()=>{
  const file=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'lava-i18n-')),'misses.jsonl');
  fs.writeFileSync(file,'');process.env.LAVA_I18N_MISSES=file;
};
