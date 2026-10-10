addEventListener("fetch", (event) => {
  event.respondWith(new Response("hello from a terrarium cell\n"));
});
