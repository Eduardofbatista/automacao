const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

async function assertRequesterIsAdmin(uid) {
  const snap = await admin.firestore().collection("usuarios").doc(uid).get();
  const role = snap.exists ? snap.data().role : undefined;
  if (role !== "admin") {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Apenas administradores podem excluir usuários."
    );
  }
}

exports.adminDeleteUser = functions
  .region("southamerica-east1")
  .https.onCall(async (data, context) => {
    try {
      if (!context.auth) {
        throw new functions.https.HttpsError(
          "unauthenticated",
          "Faça login para executar esta ação."
        );
      }

      const requesterUid = context.auth.uid;
      await assertRequesterIsAdmin(requesterUid);

      const targetUid = data && data.uid;
      if (!targetUid || typeof targetUid !== "string") {
        throw new functions.https.HttpsError(
          "invalid-argument",
          'Parâmetro "uid" é obrigatório.'
        );
      }
      if (targetUid === requesterUid) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Você não pode excluir a própria conta de admin."
        );
      }

      await admin.auth().deleteUser(targetUid).catch((err) => {
        if (err && err.code !== "auth/user-not-found") throw err;
      });

      await admin.firestore().collection("usuarios").doc(targetUid).delete().catch(() => {});

      return { ok: true };
    } catch (err) {
      console.error("adminDeleteUser error", err);
      throw new functions.https.HttpsError(
        "internal",
        err && err.message ? err.message : "Erro interno ao excluir usuário",
        { code: err && err.code }
      );
    }
  });
