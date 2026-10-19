/** Native-confirmed operation state. Renderer identity never grants authority. */
export type PreparationSnapshot = {
  id:string;
  origin:'filters'|'domainHistory';
  state:'idle'|'preparing'|'success'|'failed';
  progress:number;
  title:string;
  message:string;
  busy:boolean;
  recovery:{retry:boolean;editReturn:boolean;keepCurrent:boolean;upgrade:'frozenFilter'|'rules'|'blockedDomains'|'allowedDomains'|null};
};
export type PreparationCommand = {
  type:'preparation.enter'|'preparation.retry'|'preparation.editReturn'|'preparation.keepCurrent'|'preparation.upgrade'|'preparation.announce'|'preparation.presented'|'preparation.rendered';
  id:string;
};
/** Adapters enforce native read authority and operation-scoped command admission. */
export type PreparationCommandPort = {send:(command:PreparationCommand)=>Promise<unknown>};
export type PreparationCopy = {
  previousFilter:string;retry:string;upgrade:string;keepCurrent:string;backToEdit:string;backToReview:string;
};
