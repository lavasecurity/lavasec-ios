/** Presentation values contain no recovery phrase, passkey or account credential. */
export type AccountBackupCommand =
  | {action:'close'|'back'|'account.signOut'|'account.delete'|'setup.validate'|'setup.cancelValidation'|'setup.copy'|'setup.finish'|'setup.retry'|'restore.prepare'|'restore.confirm'}
  | {action:'setup.begin';passkey:boolean}
  | {action:'setup.consent';saved:boolean;understands:boolean}
  | {action:'restore.mode';mode:'deviceKey'|'passkey'|'recoveryCode'}
  | {action:'restore.consent';value:boolean};
export type BackupReviewRow={title:string;before:string;after:string;notes?:string[]};
export type BackupReviewSection={id:string;rows:BackupReviewRow[];notes:{text:string;role:'contentChange'|'cacheWarning'}[]};
export type AccountBackupFlowState={
  kind:'account'|'backupSetup'|'backupRestore';title:string;busy:boolean;canBack:boolean;canClose:boolean;success:boolean;
  connections:{provider:'apple'|'google';title:string}[];deleting:boolean;
  step:'overview'|'validatePasskey'|'recoveryPhrase'|'upload'|'complete';error:string;copied:boolean;canContinue:boolean;
  supportsPasskey:boolean;selectedPasskey:boolean;saved:boolean;understands:boolean;uploading:boolean;uploadError:string;
  mode:'deviceKey'|'passkey'|'recoveryCode';modes:{id:'deviceKey'|'passkey'|'recoveryCode';title:string;unavailable:boolean}[];
  status:{title:string;detail:string;tone:'green'|'warning'|'neutral'}|null;review:BackupReviewSection[]|null;
  resolverConfirmationRequired:boolean;resolverConfirmed:boolean;
};
/** Each platform supplies secure credential atoms and a controller command port. */
export type AccountBackupCommandPort=(command:AccountBackupCommand)=>void|Promise<unknown>;
