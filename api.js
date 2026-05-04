const VERIFY_URL = "https://agent.ebrahimhamdy.com/webhook/verify_token";

async function verifyToken() {
  const token = localStorage.getItem('authToken');
  if (!token) return false;
  try {
    const response = await fetch(VERIFY_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: token })
    });
    const data = await response.json();
    return data.valid === true;
  } catch(e) {
    return false;
  }
}

async function checkAuth() {
  const user  = localStorage.getItem('activeUser');
  const token = localStorage.getItem('authToken');

  if (!user || !token) {
    window.location.replace('index.html');
    return null;
  }

  const valid = await verifyToken();
  if (!valid) {
    localStorage.clear();
    window.location.replace('index.html');
    return null;
  }

  return user;
}

function logout() {
  localStorage.clear();
  window.location.replace('index.html');
}
