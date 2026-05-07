export default function middleware() {
  return Response.redirect(new URL("/api/auth/signin", "http://localhost"))
}
