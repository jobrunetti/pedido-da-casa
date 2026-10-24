# Pedido da Casa — base full-stack de testes 0.2

## O que já está nesta versão
- Interface responsiva para celular e computador (React + Vite).
- Cardápio e categorias vindos do Supabase.
- Carrinho, extras, checkout, entrega/retirada e formas de pagamento.
- Pedido gravado no banco antes de abrir WhatsApp (número de teste 5543996552815).
- Função SQL transacional que calcula o preço no banco, não confiando no total do navegador.
- Login administrativo via Supabase Auth.
- Painel para listar pedidos, atualizar status, avisar cliente no WhatsApp e abrir impressão do navegador.
- Cadastro e ativação/desativação de produtos e configurações básicas.
- RLS inicial para proteger tabelas.

## Importante
Esta é uma base inicial funcional, não deve receber pedidos reais antes de configurarmos e testarmos tudo. Ainda faltam etapas de desenvolvimento: gerenciamento completo de categorias e adicionais, edição detalhada de produtos, upload de imagens, personalização de ingredientes removidos, proteção anti-spam/limites de pedidos, testes automatizados, e registro fiel do estado da impressão. Impressão pelo navegador não confirma que o papel saiu fisicamente.

## Supabase
1. Crie um projeto.
2. Abra SQL Editor e execute todo o arquivo `supabase/schema.sql`.
3. Em Authentication > Users, crie um usuário com seu e-mail e senha.
4. No SQL Editor, rode `update public.profiles set is_admin=true where email='SEU_EMAIL_AQUI';` trocando pelo e-mail que você criou.
5. Nunca compartilhe sua senha e nunca coloque `service_role`/secret key no front-end.

## Configurar localmente
1. Copie `.env.example` para `.env.local`.
2. Preencha `VITE_SUPABASE_URL` com a Project URL e `VITE_SUPABASE_ANON_KEY` com a chave pública/publishable do Supabase.
3. Mantenha `VITE_WHATSAPP_NUMBER=5543996552815` para o teste, se esse for o número desejado.
4. Com Node.js instalado: `npm install` e depois `npm run dev`.

## Publicação Cloudflare Pages
- Conecte o repositório GitHub ao Cloudflare Pages.
- Build command: `npm run build`
- Build output directory: `dist`
- Adicione as variáveis de ambiente do `.env.local` nas configurações do projeto Cloudflare.
- Refaça a publicação após definir variáveis.

Guia oficial: https://developers.cloudflare.com/pages/framework-guides/deploy-a-react-site/
Supabase + React: https://supabase.com/docs/guides/getting-started/quickstarts/reactjs
RLS: https://supabase.com/docs/guides/database/postgres/row-level-security


## Nota de segurança
A permissão de administrador deve ser atribuída somente pelo proprietário no SQL Editor do Supabase. Não conceda ao usuário comum permissão para editar o campo `is_admin`.
