// Developer configuration only. Users sign in with Apple; they never enter API tokens.
// build.py writes the real values into the deployed copy (at /notes/config.js).
window.TASKFLOW_NOTES_CONFIG = Object.freeze({
  containerIdentifier: "iCloud.com.surratt.TaskFlow",
  environment: "development",
  apiToken: "",
  websiteURL: "https://modcaststudios.app/notes"
});
