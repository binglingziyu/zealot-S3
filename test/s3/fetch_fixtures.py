"""Download pinned upstream app-info test fixtures; verify before use."""
from pathlib import Path
import hashlib
import urllib.request

commit = 'dbd7478aef7afaa550bc9f21c558246f937ef47f'
fixtures = {
    'apps/android.apk': '4a510a6f42c8949087ece34229a619e59388e6778ba6c9ec89f9b99f2f6a211f',
    'apps/iphone.ipa': '8412b48390243aa11064c707247ca48dd74e4cd4cd2d0dbde76f161b2433c861',
    'dsyms/iOS-single-dSYM-with-single-macho.zip': '4112d710a074292a85fd4bb65f5c7f02b41662d88e3a68edbd85b177ec6b7b39',
}
directory = Path(__file__).parent / 'fixtures'
directory.mkdir(exist_ok=True)
for name, checksum in fixtures.items():
    data = urllib.request.urlopen(f'https://raw.githubusercontent.com/icyleaf/app-info/{commit}/spec/fixtures/{name}', timeout=30).read()
    assert hashlib.sha256(data).hexdigest() == checksum, name
    (directory / Path(name).name).write_bytes(data)
    print(f'Verified {name}')
