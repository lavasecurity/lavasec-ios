import {render,screen} from '@testing-library/react-native';
import {configurePresentation,localized,localizedFormat,Text} from '../app/presentation';
import {translations} from '../app/translations';

afterEach(()=>configurePresentation());

test.each([
  ['zh-Hant-TW','zh-Hant'],['zh_TW','zh-Hant'],['zh-HK','zh-Hant'],
  ['ZH-hant-mo','zh-Hant'],['zh-Hans-HK','zh-Hans'],['zh-CN','zh-Hans'],
  ['fr-CA','fr'],['de-DE','de'],['pt-PT','pt-BR'],['pt','pt-BR'],
  ['en-GB','en'],['pl-PL','en'],
])('rendered copy resolves %s to the supported %s catalog',(locale,catalog)=>{
  configurePresentation({locale,textScales:null});
  render(<Text>VPN chaining</Text>);
  expect(screen.getByText(translations[catalog]!['VPN chaining']!)).toBeOnTheScreen();
  expect(localized('Guard')).toBe(translations[catalog]!['Guard']);
});

test('the reported VPN setup status renders in every supported language',()=>{
  for(const [locale,table] of Object.entries(translations)) {
    configurePresentation({locale,textScales:null});
    const value=localized('Setting up VPN chaining.');
    expect(value).toBe(table['Setting up VPN chaining.']);
    if(locale!=='en')expect(value).not.toBe('Setting up VPN chaining.');
  }
  configurePresentation({locale:'zh-Hant',textScales:null});
  render(<Text>Setting up VPN chaining.</Text>);
  expect(screen.getByText('正在設定 VPN 串接。')).toBeOnTheScreen();
});

test('localized formats keep runtime names intact and verbatim text preserves identity',()=>{
  configurePresentation({locale:'zh-Hant-TW',textScales:null});
  const format='Your primary DNS is %@. For more details, check DNS settings.';
  expect(localizedFormat(format,'Cancel')).toBe(translations['zh-Hant']![format]!.replace('%@','Cancel'));
  render(<Text verbatim>Cancel</Text>);
  expect(screen.getByText('Cancel')).toBeOnTheScreen();
  expect(localized('Cancel')).not.toBe('Cancel');
});
