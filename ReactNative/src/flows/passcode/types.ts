/** Public presentation metadata only. A platform adapter owns every credential byte. */
export type PasscodeState={id:string;authenticating:boolean;title:string;subtitle:string;message:string};
export type PasscodeCommand={type:'passcode.command';id:string;action:'cancel'|'focus'}
  |{type:'passcode.header';id:string;title:string;cancelTitle:string;showCancel:boolean};
