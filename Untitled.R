library(sf)
library(terra)
library(ggplot2)

filename <- system.file("nicaragua.sqlite", package = "terra")
# list or delete layers in a vector database 
vector_layers("nicaragua.sqlite", delete="", return_error=FALSE)


points <- vect("nicaragua.sqlite", layer="points" )
lines <- vect("nicaragua.sqlite", layer="lines" )
multilinestrings <- vect("nicaragua.sqlite", layer="multilinestrings" )
multipolygons<- vect("nicaragua.sqlite", layer="multipolygons" )

k <- subset(multipolygons, multipolygons$leisure %in% c("park","nature_reserve"))

k_sf <- st_as_sf(k)

ggplot(k_sf) +
  geom_sf(aes(fill="green")) +
  theme_bw()

terra::plot(k,  box= T,
            col="lightgreen",
            lwd=1,
            border=c("black"),
             pax=list(side=1:2, retro=T),
#             plg=list(),
             main="Nicaragua. Zonas verdes"
           )

f <- subset(multipolygons, multipolygons$amenity %in% c("pharmacy"))
terra::plot(f,
            main="Nicaragua. Farmacias")


