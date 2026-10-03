export type PresentationReadTicket={epoch:number;id:number};
export type PresentationHydrationSnapshot={epoch:number;required:boolean};

/** Warm resumes keep erased content covered until the current focused reads settle. */
export class PresentationHydration {
  private snapshot:PresentationHydrationSnapshot={epoch:0,required:false};
  private pending=new Set<number>();
  private nextRead=0;
  private layoutComplete=false;
  private releaseScheduled=false;
  constructor(private readonly changed:()=>void) {}
  getSnapshot=()=>this.snapshot;
  beginBoundary() {
    this.pending.clear();this.layoutComplete=false;
    this.snapshot={epoch:this.snapshot.epoch+1,required:true};this.changed();
  }
  registerRead():PresentationReadTicket|undefined {
    if(!this.snapshot.required)return;
    const ticket={epoch:this.snapshot.epoch,id:++this.nextRead};this.pending.add(ticket.id);return ticket;
  }
  settleRead(ticket?:PresentationReadTicket) {
    if(!ticket||ticket.epoch!==this.snapshot.epoch)return;
    this.pending.delete(ticket.id);this.scheduleRelease();
  }
  completeLayout(epoch:number) {
    if(epoch!==this.snapshot.epoch||!this.snapshot.required)return;
    this.layoutComplete=true;this.scheduleRelease();
  }
  reset() {
    this.pending.clear();this.layoutComplete=false;
    this.snapshot={epoch:this.snapshot.epoch+1,required:false};this.changed();
  }
  private scheduleRelease() {
    if(this.releaseScheduled)return;
    this.releaseScheduled=true;
    // Scope/navigation layout cleanup can retire one read just before the next
    // mounted read registers. Batch that turn so zero pending is never a gap.
    void Promise.resolve().then(()=>{
      this.releaseScheduled=false;
      if(!this.snapshot.required||!this.layoutComplete||this.pending.size)return;
      this.snapshot={...this.snapshot,required:false};this.changed();
    });
  }
}
