export type PresentationReadTicket={epoch:number;id:number};
export type PresentationHydrationSnapshot={epoch:number;required:boolean};

/** Initial and resumed presentations admit their current layout and focused reads together. */
export class PresentationHydration {
  private snapshot:PresentationHydrationSnapshot={epoch:0,required:false};
  private pending=new Set<number>();
  private nextRead=0;
  private layoutComplete=false;
  private releaseScheduled=false;
  private initialPresentation=false;
  constructor(private readonly changed:()=>void) {}
  getSnapshot=()=>this.snapshot;
  isInitialPresentation=()=>this.initialPresentation;
  beginInitialPresentation() {this.beginBoundary();this.initialPresentation=true;}
  beginBoundary() {
    this.initialPresentation=false;
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
    this.initialPresentation=false;
    this.pending.clear();this.layoutComplete=false;
    this.snapshot={epoch:this.snapshot.epoch+1,required:false};this.changed();
  }
  private scheduleRelease() {
    if(this.releaseScheduled)return;
    this.releaseScheduled=true;
    // Scope/navigation layout cleanup can retire one read just before the next
    // mounted read registers. Batch that turn so zero pending is never a gap.
    void Promise.resolve().then(()=>{
      if(!this.snapshot.required||!this.layoutComplete||this.pending.size){this.releaseScheduled=false;return;}
      this.releaseScheduled=false;
      // Readiness arrives from committed layout effects, not promise resolution.
      // Removing React's cover is another commit. The root acknowledges native
      // after that commit's frame; waiting for a frame here would do it twice.
      this.initialPresentation=false;
      this.snapshot={...this.snapshot,required:false};this.changed();
    });
  }
}
