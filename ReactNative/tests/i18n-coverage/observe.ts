// Records every localized() lookup the native catalog lacks, for global-teardown.js.
import {appendFileSync} from 'node:fs';
import {observeMissingTranslations} from '../../app/presentation';

const file=process.env.LAVA_I18N_MISSES;
if(file)observeMissingTranslations(value=>appendFileSync(file,JSON.stringify(value)+'\n'));
