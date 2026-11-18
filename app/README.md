# Personal History Organizer
The purpose of this app is to make handling your personal history easy. Take pictures of your handwritten journals, transcribe them into computer-searchable text, and discuss them with an AI agent. Everything is local, nothing leaves your device. 
## Future Features
- Entry View
  - attach family photos to journal entries
  - clickable entries with edit features within the entry view (DONE)
  - 'View Page' button pulling up the page image for easy reference (DONE)
  - entry view links to the page view, and vice versa (DONE)
  - updated red boxes so the user knows what they mean and they look good (label saying 'needs review'?)
  - Highlight entries with the same date or a date out of order from the rest of the page for review
- Entries Page
  - Filter options (so that we can show the page filtered to just entries from one Page) (DONE)
  - Better search functionality (better placement, smarter search, filters) (DONE)
- Transcription Flow
  - improve transcription (sometimes adds \\n and gets the date wrong)
- Page View
  - entry view links to the page view, and vice versa
  - updated red boxes so the user knows what they mean and they look good (label saying 'needs review'?)
- Design
  - consistent logo and color scheme
- Settings Page
- Additional Import Locations
  - import journal entries from other text formats
- Chat Page
  - Add a chatbot that has access to all the journal entries and dates in the app. RAG?
- Export Flow
  - export all or some of your personal history for ease of backups and sharing
- Cloud Storage?
- Entry/Page Organization
  - organize photos in a grid
  - sort by page date/transcription date
  - group into albums
- Optimization
  - opening the app for the first time is really slow (loading things into ram?)
  - Add tests


Alright, I want to build a EntryView screen that the user can go into when they clock on a specific entry.   
  The main screen should be the text of the entry in the middle, the date of the entry above that, edit buttons next 
  to the date and text, and a button in the bottom right that says 'Go to Page' that sends the user to the PageView  
  screen of the page that this entry is attached to. 


- photo adjustments in the app (DONE)
- remove all traces of FastVLM app (DONE)
- fix image crop (DONE)
- delete dialogue on pages and entries is off-centered (DONE)
- 'x' button on transcribe verification page is squished in the corner (DONE)
