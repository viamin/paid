from django.urls import path

urlpatterns = [
    path("", lambda request: None, name="home"),
    path("admin/", lambda request: None, name="admin"),
    path("accounts/login/", lambda request: None, name="login"),
]
