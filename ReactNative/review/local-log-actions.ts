import {useEffect,useRef,useState} from 'react';
import {useIsFocused} from '@react-navigation/native';
import {useAppAction} from '../app/actions';
import {mayInteractWithPresentation} from '../app/read-cache';
import {Alert,isPresentationCancellation,localized,localizedFormat} from '../app/presentation';
import {useReview} from './ReviewContext';
import {previewNotice} from './navigation';

// Activity and Privacy share the same app-settings-authorized operations. The
// Activity date range never narrows an export or a clear-all request.
export function useLocalLogActions() {
  const {app,live}=useReview();const run=useAppAction();
  const mounted=useRef(true);const focused=useIsFocused();
  const focus=useRef(focused);focus.current=focused;
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  const canAct=()=>mounted.current&&focus.current&&mayInteractWithPresentation(app);
  const exportPending=useRef(false);const clearPending=useRef(false);const confirmationPending=useRef(false);
  const [isExporting,setIsExporting]=useState(false);const [isClearing,setIsClearing]=useState(false);
  const [exportError,setExportError]=useState<string>();
  const exportBusy=isExporting||!!live?.logExportBusy;
  const exportLogs=(domains=false)=>{
    if(exportPending.current||live?.logExportBusy||!canAct())return;
    setExportError(undefined);
    if(!app){previewNotice();return;}
    exportPending.current=true;setIsExporting(true);
    void app.command({type:'logs.export',domains})
      .catch(error=>{if(mounted.current&&!isPresentationCancellation(error.message))setExportError(localizedFormat('Could not export local logs: %@',localized(error.message)));})
      .finally(()=>{exportPending.current=false;if(mounted.current)setIsExporting(false);});
  };
  const clearAllLogs=()=>{
    if(confirmationPending.current||clearPending.current||!canAct())return;
    const contract=live?.confirmations?.['Clear all logs'];
    if(!app||!contract){previewNotice();return;}
    const epoch=app.getReadEpoch?.();
    confirmationPending.current=true;let consumed=false;
    const dismiss=()=>{consumed=true;confirmationPending.current=false;};
    Alert.alert(contract.title,contract.message,[
      {text:'Cancel',style:'cancel',onPress:dismiss},
      {text:contract.action,style:'destructive',onPress:()=>{
        if(consumed)return;
        dismiss();
        if(!canAct()||app.getReadEpoch?.()!==epoch)return;
        clearPending.current=true;setIsClearing(true);
        // AppStore retires cached log reads and refreshes every affected page.
        // Keep app-settings authentication, including when launched from Activity.
        void Promise.resolve(run({type:'logs.clear',kind:'Clear all logs'}))
          .finally(()=>{clearPending.current=false;if(mounted.current)setIsClearing(false);});
      }},
    ],{onDismiss:dismiss});
  };
  return {exportLogs:()=>exportLogs(false),exportAllLogs:()=>exportLogs(true),exportBusy,exportError:!isExporting?(exportError||live?.logExportError):undefined,
    clearAllLogs,clearBusy:isClearing};
}
