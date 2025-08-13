
const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

async function isCallerAdmin(context) {
  const uidCaller = context.auth?.uid;
  if (!uidCaller) {
    throw new functions.https.HttpsError("unauthenticated", "Faça login.");
  }
  const doc = await admin.firestore().collection("usuarios").doc(uidCaller).get();
  if (!doc.exists || doc.data()?.role !== "admin") {
    throw new functions.https.HttpsError("permission-denied", "Apenas admin pode executar esta ação.");
  }
}

exports.adminDeleteUser = functions.https.onCall(async (data, context) => {
  await isCallerAdmin(context);

  const uidToDelete = data?.uid;
  if (!uidToDelete || typeof uidToDelete !== "string") {
    throw new functions.https.HttpsError("invalid-argument", "Parâmetro 'uid' inválido ou ausente.");
  }

  await admin.auth().deleteUser(uidToDelete);

  await admin.firestore().collection("usuarios").doc(uidToDelete).set({
    ativo: false,
    deletedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { ok: true };
});

