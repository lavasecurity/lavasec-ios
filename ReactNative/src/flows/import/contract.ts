import type {ReactNode} from 'react';

export type ImportStage='chooseMethod'|'enterCode'|'scanCode'|'confirm'|'chooseReplace'|'reviewReplacement'|'applying'|'completed';
export type ImportDisplayRow={id:string;title:string;metadata:string;verbatim:boolean};
export type ImportReview={blocked:ImportDisplayRow[];allowed:string[]|null;canImport:boolean;showUpgrade:boolean;upgradeRows:string[];warnings:{message:string;quiet:boolean}[]};
export type ImportState={
  stage:ImportStage;stageID:string;direction:'forward'|'backward';code:string;error:string;cameraDenied:boolean;
  checkingCatalog:boolean;catalogCheckFailed:boolean;decodingPhoto:boolean;canDismiss:boolean;closeAtRoot?:boolean;alertID:string;
  alert?:{title:string;message:string;tint?:'app'|'confirmation'};activeReplacement?:{id:string;message:string};review?:ImportReview;
  targets?:{id:string;name:string;summary:string;locked:boolean}[];
  replacement?:{name:string;removed:string;groups:{title:string;removed:string[];added:string[]}[]};
  completed?:{message:string;unavailable:string};
};
export type ImportAction=
  |{type:'import.method';method:'code'|'scan'|'photo'}
  |{type:'import.code'|'import.continue';value:string}
  |{type:'import.target';target:string}
  |{type:'import.confirmActive';confirmation:string}
  |{type:'import.back'|'import.dismiss'|'import.retry'|'import.add'|'import.targets'|'import.replace'|'import.clearAlert'|'import.upgrade'|'import.done'|'import.cameraRetry'|'import.cameraSettings'};
export type ImportCommand=ImportAction&{id:string;stageID:string};
export type ImportPort={command:(action:ImportAction)=>Promise<unknown>;scanner:ReactNode;measure?:(height:number)=>void};

export const importTitles:Record<ImportStage,string>={chooseMethod:'Import a filter',enterCode:'Enter a code',scanCode:'Scan a QR code',confirm:'Review import',chooseReplace:'Replace a filter',reviewReplacement:'Review import',applying:'',completed:''};
