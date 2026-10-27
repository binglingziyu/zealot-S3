const {chromium} = require('playwright');
const fs = require('fs');
(async () => {
 const fixture = JSON.parse(fs.readFileSync('/tmp/zealot-browser-fixture.json'));
 const browser = await chromium.launch({channel:'chrome',headless:true});
 const page = await browser.newPage({viewport:{width:1365,height:1000}});
 const traffic=[], errors=[], observations=[];
 page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{ if(['POST','PUT','DELETE'].includes(r.method())) observations.push((async()=>{const u=new URL(r.url()); const headers=await r.allHeaders(); traffic.push({method:r.method(),port:u.port,path:u.pathname,bytes:r.postDataBuffer()?.length||Number(headers['content-length'])||0});})()); });
 await page.goto('http://127.0.0.1:18902/users/sign_in');
 await page.locator('#user_email').first().fill('s3-test@zealot.test');
 await page.locator('#user_password').fill('s3-test-admin-password');
 await Promise.all([page.waitForURL(u=>!u.pathname.includes('sign_in')),page.locator('input[type=submit]').first().click()]);
 const cases=[['apk',fixture.android_path,'android.apk'],['ipa',fixture.ios_path,'iphone.ipa'],['debug','/debug_files/new','iOS-single-dSYM-with-single-macho.zip']];
 for(const [kind,path,file] of cases) {
   await page.goto('http://127.0.0.1:18902'+path);
   await page.locator('[data-controller=direct-upload]').waitFor();
   if(kind==='debug') {
     await page.locator('#direct-channel').selectOption(fixture.debug_key);
     await page.locator('[name=release_version]').fill('1.0');
     await page.locator('[name=build_version]').fill('1');
   }
   await page.locator('#direct-file').setInputFiles(require('path').join(__dirname, '../fixtures', file));
   await page.screenshot({path:`/tmp/zealot-browser-${kind}-form.png`,fullPage:true});
   await page.locator('[data-direct-upload-target=submit]').click();
   try {
     await page.waitForURL(u=>kind==='debug'?/\/debug_files\/\d+$/.test(u.pathname):/\/releases\/\d+$/.test(u.pathname),{timeout:180000});
   } catch(error) {
     console.log({kind,status:await page.locator('[data-direct-upload-target=status]').textContent(),errors});
     throw error;
   }
   await page.screenshot({path:`/tmp/zealot-browser-${kind}-result.png`,fullPage:true});
   console.log(`${kind}: published through browser`);
 }
 await Promise.all(observations);
 const packageRequests=traffic.filter(t=>t.method==='PUT');
 if(packageRequests.some(t=>t.bytes===0))throw new Error('Missing storage request byte-count evidence');
 if(packageRequests.length<3||packageRequests.some(t=>t.port!=='18903'))throw new Error('Package bytes did not go exclusively to storage');
 if(traffic.some(t=>t.port==='18902'&&t.bytes>65536))throw new Error('Large body sent to application server');
 if(errors.length)throw new Error('Browser JavaScript errors: '+errors.join(';'));
 console.log(JSON.stringify({storageRequests:packageRequests,largestControlBody:Math.max(...traffic.filter(t=>t.port==='18902').map(t=>t.bytes))}));
 fs.writeFileSync('/tmp/zealot-browser-traffic.json',JSON.stringify(traffic,null,2));
 await browser.close();
})().catch(e=>{console.error(e.message);process.exit(1)});
