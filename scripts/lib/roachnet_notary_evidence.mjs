import path from 'node:path'

export function parseAcceptedNotarySubmission(output, artifactPath) {
  let submission
  try {
    submission = JSON.parse(output)
  } catch {
    throw new Error(`Apple notarization returned malformed JSON for ${artifactPath}.`)
  }

  if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(submission?.id || '')) {
    throw new Error(`Apple notarization submission ID is invalid for ${artifactPath}.`)
  }
  if (submission.status !== 'Accepted') {
    throw new Error(`Apple notarization did not return Accepted for ${artifactPath}.`)
  }

  return {
    artifact: path.basename(artifactPath),
    submissionId: submission.id,
    status: submission.status,
  }
}
