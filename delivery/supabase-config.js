const SUPABASE_URL = 'https://rxtjoqulmgkkcohmgzgi.supabase.co';
const SUPABASE_KEY = 'sb_publishable_O3icoIIQ5ptdzZ3UYLdaug_ktq63i0Q';

const { createClient } = supabase;
const db = createClient(SUPABASE_URL, SUPABASE_KEY);
