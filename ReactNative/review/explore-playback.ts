/** One reading/speech wait owns a generation; manual input invalidates both. */
export class DemoPlaybackClock {
  private generation=0;
  private timer:ReturnType<typeof setTimeout>|undefined;

  cancel(){
    this.generation++;
    if(this.timer!==undefined)clearTimeout(this.timer);
    this.timer=undefined;
  }

  start(readingMilliseconds:number,speech:Promise<unknown>,advance:()=>void){
    this.cancel();const generation=this.generation;
    const reading=new Promise<void>(resolve=>{this.timer=setTimeout(()=>{this.timer=undefined;resolve();},readingMilliseconds);});
    void Promise.all([reading,speech.catch(()=>false)]).then(()=>{
      if(this.generation===generation)advance();
    });
  }
}
