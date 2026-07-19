const SUPABASE_URL = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4dGpvcXVsbWdra2NvaG1nemdpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQ2OTUsImV4cCI6MjA5NDI4MDY5NX0.QVoJPtlRlRIz9tdhmdTZxHtKxrwAxJq0Je4QHkFKxj0';

const { createClient } = supabase;
const _authJwt = localStorage.getItem('authJwt');
const db = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: { headers: _authJwt ? { Authorization: 'Bearer ' + _authJwt } : {} }
});
