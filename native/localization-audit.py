#!/usr/bin/env python3
"""Extract English source keys using Apple's tools; never fabricate reviewed translations."""
import json,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parent
source=root/'Sources/SideloomNative'
out=source/'Localization'
out.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='slip-localization-') as temp:
    subprocess.run(['xcrun','xcstringstool','extract','--SwiftUI','--modern-localizable-strings','--legacy-localizable-strings',*map(str,sorted(source.glob('*.swift'))),'--output-directory',temp],check=True)
    keys=set()
    for file in Path(temp).glob('*.stringsdata'):
        keys.update(row['key'] for row in json.loads(file.read_text()).get('tables',{}).get('Localizable',[]))
    catalog={'sourceLanguage':'en','strings':{key:{'localizations':{'en':{'stringUnit':{'state':'translated','value':key}}}} for key in sorted(keys)},'version':'1.0'}
    path=out/'Localizable.xcstrings'
    path.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
    subprocess.run(['xcrun','xcstringstool','compile',str(path),'--output-directory',str(out),'--language','en'],check=True)
report=f'# Localization3.0\n\n{len(keys)} extractable English keys. Typed diagnostics use localized lookup. Dynamic unmarked strings and older-core messages remain English. This is not complete localization.\n\n'
report+='Target es,fr,de,pt-BR,ja,zh-Hans,hi:0 reviewed translations available; English fallback. No unreviewed security choices ship. Stable schema/error codes stay untranslated. System formatting remains locale-aware; full plural/VoiceOver/pseudo/RTL review remains manual. Regeneration replaces source baseline; merge future reviewed translations before enabling locales.\n'
(root.parent/'docs/LOCALIZATION_3.0.0.md').write_text(report)
print(f'{len(keys)} English keys extracted')
