// Developer configuration only. Users authenticate with Apple; never enter API tokens.
// Register https://modcaststudios.app as an allowed origin in CloudKit.
window.TASKFLOW_NOTES_CONFIG = Object.freeze({
  containerIdentifier: "iCloud.com.surratt.TaskFlow",
  environment: "development",
  apiToken: "",
  websiteURL: "https://modcaststudios.app/notes/"
});
