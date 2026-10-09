from pathlib import Path
import re, html
from reportlab.platypus import BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, PageBreak, KeepTogether
from reportlab.platypus.tableofcontents import TableOfContents
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib import colors
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.enums import TA_LEFT
from pypdf import PdfReader
ROOT=Path('/Volumes/Disk 2/TaskFlow')
OUT=ROOT/'output/pdf/TaskFlow-1.14-Users-Guide.pdf'
pdfmetrics.registerFont(TTFont('Guide','/System/Library/Fonts/Supplemental/Arial.ttf'))
pdfmetrics.registerFont(TTFont('GuideBold','/System/Library/Fonts/Supplemental/Arial Bold.ttf'))
pdfmetrics.registerFontFamily('Guide',normal='Guide',bold='GuideBold',italic='Guide',boldItalic='GuideBold')
navy=colors.HexColor('#142C44'); blue=colors.HexColor('#1769A8'); gray=colors.HexColor('#526273')
styles=getSampleStyleSheet()
styles.add(ParagraphStyle(name='BodyGuide',fontName='Guide',fontSize=10.5,leading=15,spaceAfter=8,textColor=navy))
styles.add(ParagraphStyle(name='ChapterGuide',fontName='GuideBold',fontSize=23,leading=28,spaceAfter=16,textColor=navy))
styles.add(ParagraphStyle(name='SubGuide',fontName='GuideBold',fontSize=12,leading=16,spaceBefore=9,spaceAfter=5,textColor=blue,keepWithNext=True))
styles.add(ParagraphStyle(name='ListGuide',parent=styles['BodyGuide'],leftIndent=13,firstLineIndent=-10,spaceAfter=5))
styles.add(ParagraphStyle(name='ContentsGuide',fontName='Guide',fontSize=10,leading=14,spaceAfter=3,textColor=navy))
styles.add(ParagraphStyle(name='CoverGuide',fontName='GuideBold',fontSize=45,leading=50,textColor=navy,spaceAfter=18))
styles.add(ParagraphStyle(name='CoverSubGuide',fontName='Guide',fontSize=18,leading=26,textColor=gray,spaceAfter=22))
class GuideDoc(BaseDocTemplate):
    def afterFlowable(self,flow):
        if isinstance(flow,Paragraph) and flow.style.name=='ChapterGuide':
            title=flow.getPlainText(); key='chapter-'+title[:2]
            self.canv.bookmarkPage(key); self.canv.addOutlineEntry(title,key,level=0)
            self.notify('TOCEntry',(0,title,self.page,key))
def page(c,doc):
    c.saveState()
    if doc.page==1:
        c.setFillColor(blue);c.rect(0,745,612,47,fill=1,stroke=0)
        c.setFillColor(colors.HexColor('#EAF2F8'));c.rect(0,0,612,160,fill=1,stroke=0)
        c.setFillColor(colors.white);c.setFont('GuideBold',11);c.drawString(48,762,'TASKFLOW STUDIO  /  VERSION 1.14')
    else:
        c.setFillColor(gray);c.setFont('Guide',8.5);c.drawString(48,760,'TASKFLOW 1.14  |  USER\'S GUIDE')
        c.setStrokeColor(colors.HexColor('#D7E1E8'));c.line(48,750,564,750)
    c.setFont('Guide',8);c.setFillColor(gray);c.drawString(48,30,'October 2026  •  TaskFlow Studio');c.drawRightString(564,30,str(doc.page))
    c.restoreState()
doc=GuideDoc(str(OUT),pagesize=(612,792),leftMargin=48,rightMargin=48,topMargin=61,bottomMargin=51,title="TaskFlow 1.14 User's Guide",author='TaskFlow Studio',subject='Setup, tasks, calendars, notes, shopping, Watch Later, widgets, and troubleshooting')
doc.addPageTemplates(PageTemplate(id='Guide',frames=[Frame(48,51,516,680,id='body',leftPadding=0,rightPadding=0,topPadding=0,bottomPadding=0)],onPage=page))
def markup(text):
    t=html.escape(text).replace('—','-').replace('–','-').replace('‑','-')
    t=re.sub(r'\*\*(.+?)\*\*',r'<b>\1</b>',t)
    t=t.replace('https://modcaststudios.app/notes','<link href="https://modcaststudios.app/notes" color="#1769A8">modcaststudios.app/notes</link>')
    return t
story=[Spacer(1,93),Paragraph('TaskFlow 1.14',styles['CoverGuide']),Paragraph("User's Guide",styles['CoverGuide']),Paragraph('Make room for what matters.',styles['CoverSubGuide']),Paragraph('Tasks • Calendars • Notes<br/>Shopping • Watch Later • Widgets',styles['CoverSubGuide']),Spacer(1,26),Paragraph('A practical reference with guided workflows,<br/>quick-start steps, and troubleshooting.',styles['BodyGuide']),Spacer(1,73),Paragraph('Prepared October 7, 2026',styles['BodyGuide']),Paragraph('Covers the 1.14 feature set and latest interface updates.<br/>Menu layouts can vary by device and installed build.',styles['BodyGuide']),PageBreak(),Paragraph('Contents',styles['ChapterGuide'])]
# Contents should not enter itself in the chapter outline / TOC
story[-1].style=ParagraphStyle('ContentsTitle',parent=styles['ChapterGuide'])
story.append(Paragraph('Choose a chapter here or use the PDF bookmarks. Chapter links and the Web Notes address are clickable.',styles['BodyGuide']))
toc=TableOfContents();toc.levelStyles=[styles['ContentsGuide']];story += [toc,PageBreak()]
source=(ROOT/'output/pdf/TaskFlow-1.14-Users-Guide.md').read_text()
chapters=re.split(r'^## ',source,flags=re.M)[1:]
for i,ch in enumerate(chapters):
    title,body=ch.split('\n',1)
    story.append(Paragraph(markup(title),styles['ChapterGuide']))
    paragraphs=re.split(r'\n\s*\n',body.strip())
    for p in paragraphs:
        if p.startswith('### '):
            lines=p.splitlines();story.append(Paragraph(markup(lines[0][4:]),styles['SubGuide']))
            p='\n'.join(lines[1:]).strip()
            if not p:continue
        if p.startswith('- ') or re.match(r'^\d+\. ',p):
            for line in p.splitlines():
                if line.startswith('- '): txt='• '+line[2:]
                else: txt=line
                story.append(Paragraph(markup(txt),styles['ListGuide']))
        else:story.append(Paragraph(markup(' '.join(p.splitlines())),styles['BodyGuide']))
    if i<len(chapters)-1:story.append(PageBreak())
doc.multiBuild(story)
r=PdfReader(OUT)
print(f'Created {len(r.pages)} pages; {OUT.stat().st_size:,} bytes')
for n,p in enumerate(r.pages,1):
    t=p.extract_text()
    if len(t.strip())<100:print('Sparse page:',n)
print('Chapters:',len(chapters),'Words:',len(source.split()))
