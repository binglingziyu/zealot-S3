const {chromium} = require('playwright');
const fs=require('fs');
(async()=>{
 const fixture=JSON.parse(fs.readFileSync('/tmp/zealot-browser-fixture.json'));
 const file='/tmp/zealot-browser-resume.bin';fs.writeFileSync(file,Buffer.alloc(20*1024*1024,120));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 const page=await browser.newPage({viewport:{width:1365,height:1000}});
 await page.goto('http://127.0.0.1:18902/users/sign_in');
 await page.locator('#user_email').first().fill('s3-test@zealot.test');await page.locator('#user_password').fill('s3-test-admin-password');
 await Promise.all([page.waitForURL(u=>!u.pathname.includes('sign_in')),page.locator('input[type=submit]').first().click()]);
 let fault=true;const attempts={};
 await page.route('http://127.0.0.1:18903/**',async route=>{
   const r=route.request(), u=new URL(r.url());
   if(r.method()==='PUT'){
     const number=u.searchParams.get('partNumber');attempts[number]=(attempts[number]||0)+1;
     if(fault&&number==='2')return route.abort('internetdisconnected');
   }
   return route.continue();
 });
 await page.goto('http://127.0.0.1:18902'+fixture.linux_path);
 await page.locator('#direct-file').setInputFiles(file);await page.locator('[data-direct-upload-target=submit]').click();
 await page.waitForFunction(()=>document.querySelector('[data-direct-upload-target=status]')?.textContent.includes('可点击'),{},{timeout:60000});
 await page.screenshot({path:'/tmp/zealot-browser-resume-error.png',fullPage:true});
 if(attempts['1']!==1||attempts['2']!==3)throw new Error('Unexpected failed upload attempts '+JSON.stringify(attempts));
 fault=false;await page.locator('[data-direct-upload-target=submit]').click();
 await page.waitForURL(u=>/\/releases\/\d+$/.test(u.pathname),{timeout:180000});
 if(attempts['1']!==1||attempts['2']!==4)throw new Error('Already stored part was retransmitted '+JSON.stringify(attempts));
 console.log('Browser resumed only the missing part: '+JSON.stringify(attempts));
 await browser.close();
})().catch(e=>{console.error(e.message);process.exit(1)});
