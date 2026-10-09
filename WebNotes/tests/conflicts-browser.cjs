const { chromium } = require(process.env.PLAYWRIGHT_PATH || '/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/playwright');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless:true});
  try {
    const page = await browser.newPage();
    await page.route('**/config.js', route => route.fulfill({contentType:'text/javascript',body:'window.TASKFLOW_NOTES_CONFIG={containerIdentifier:"test",environment:"development",apiToken:"fake-local-test"};'}));
    await page.route('https://cdn.apple-cloudkit.com/**', route => route.fulfill({contentType:'text/javascript',body:`
      window.testRecords=new Map();window.testCounter=0;window.testDelay=0;window.testListDelay=0;window.testFail=false;
      const db={
        fetchRecords:async name=>({records:name==='TaskFlowWebNotesReady'?[{fields:{schemaVersion:{value:1}}}]:[structuredClone(testRecords.get(name))]}),
        performQuery:async()=>{const records=[...testRecords.values()].map(structuredClone);await new Promise(r=>setTimeout(r,testListDelay));return {records};},
        saveRecords:async record=>{await new Promise(r=>setTimeout(r,testDelay)); if(testFail)return {hasErrors:true,errors:[{ckErrorCode:'QUOTA_EXCEEDED'}]};const current=testRecords.get(record.recordName);if(current&&current.recordChangeTag!==record.recordChangeTag)return {hasErrors:true,errors:[{ckErrorCode:'CONFLICT'}]};const saved={...record,recordChangeTag:String(++testCounter)};testRecords.set(record.recordName,structuredClone(saved));return {records:[structuredClone(saved)]};}
      };
      window.CloudKit={configure(){},getDefaultContainer(){return {privateCloudDatabase:db,setUpAuth:async()=>({userRecordName:'browser-test-account'}),whenUserSignsIn:()=>Promise.resolve(),whenUserSignsOut:()=>new Promise(resolve=>{window.testExpire=resolve;}),signOut:async()=>{}}}};
    `}));
    await page.goto('http://127.0.0.1:8765/');
    await page.getByRole('button',{name:'Continue with iCloud'}).click();
    await page.locator('#workspace').waitFor({state:'visible'});
    await page.getByRole('button',{name:'New note',exact:true}).click();
    await page.getByRole('textbox',{name:'Note title',exact:true}).fill('Conflict note');
    await page.getByRole('textbox',{name:'Note content',exact:true}).fill('Base');
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.waitForFunction(()=>[...testRecords.values()].some(r=>JSON.parse(r.fields.payload.value).text==='Base'));
    await page.evaluate(()=>{const r=[...testRecords.values()][0];const payload=JSON.parse(r.fields.payload.value);payload.text='Edited elsewhere';r.fields.payload.value=JSON.stringify(payload);r.recordChangeTag=String(++testCounter);});
    await page.getByRole('textbox',{name:'Note content',exact:true}).fill('My unsaved edit');
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.locator('#conflict-dialog').waitFor({state:'visible'});
    assert.match(await page.locator('#conflict-remote').innerText(),/Edited elsewhere/);
    await page.getByRole('button',{name:'Decide Later'}).click();
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.locator('#conflict-dialog').waitFor({state:'visible'});
    await page.getByRole('button',{name:'Keep Both',exact:true}).click();
    await page.locator('#conflict-dialog').waitFor({state:'hidden'});
    const content=await page.evaluate(()=>[...testRecords.values()].map(r=>JSON.parse(r.fields.payload.value).text));
    assert.ok(content.includes('My unsaved edit'));assert.ok(content.includes('Edited elsewhere'));
    await page.evaluate(()=>{testDelay=250;});
    await page.getByRole('textbox',{name:'Note content',exact:true}).fill('First in-flight edit');
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.getByRole('textbox',{name:'Note content',exact:true}).fill('Newest in-flight edit');
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.waitForFunction(()=>[...testRecords.values()].some(r=>JSON.parse(r.fields.payload.value).text==='Newest in-flight edit'));
    assert.equal(await page.locator('#conflict-dialog').isVisible(),false);
    // A refresh snapshot taken before typing must not replace the new editor contents.
    await page.evaluate(()=>{testListDelay=350;});
    await page.getByRole('button',{name:'Refresh',exact:true}).click();
    await page.getByRole('textbox',{name:'Note content',exact:true}).fill('Typed during refresh');
    await page.waitForTimeout(500);
    assert.equal(await page.getByRole('textbox',{name:'Note content',exact:true}).innerText(),'Typed during refresh');
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.waitForFunction(()=>[...testRecords.values()].some(r=>JSON.parse(r.fields.payload.value).text==='Typed during refresh'));
    await page.evaluate(()=>{testFail=true;});
    await page.getByRole('textbox',{name:'Note content',exact:true}).fill('Offline draft');
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.getByText('Your iCloud storage is full.',{exact:false}).first().waitFor();
    assert.equal(await page.getByRole('textbox',{name:'Note content',exact:true}).innerText(),'Offline draft');
    assert.ok(await page.evaluate(()=>Object.keys(sessionStorage).some(k=>k.startsWith('TaskFlow.notes.draft.'))));
    // Session recovery retains the original change tag for later conflict detection.
    await page.reload(); await page.getByRole('button',{name:'Continue with iCloud'}).click();
    await page.locator('#workspace').waitFor({state:'visible'});
    assert.equal(await page.getByRole('textbox',{name:'Note content',exact:true}).innerText(),'Offline draft');
    // Account expiry during a save must not resurrect note content when it finishes.
    await page.evaluate(()=>{testDelay=500;});
    await page.getByRole('textbox',{name:'Note content',exact:true}).fill('Pending at sign out');
    await page.getByRole('button',{name:'Save Now'}).click();
    await page.evaluate(()=>testExpire());
    await page.locator('#welcome').waitFor({state:'visible'});
    await page.waitForTimeout(650);
    assert.equal(await page.locator('#note-body .ql-editor').innerText(),'');
    assert.equal(await page.locator('.note-card').count(),0);
    assert.equal(await page.evaluate(()=>Object.keys(sessionStorage).some(k=>k.startsWith('TaskFlow.notes.draft.'))),false);
    console.log('Browser reliability checks passed: conflict detection, decide later, keep both, edits during save, failed-save draft retention, reload recovery.');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
